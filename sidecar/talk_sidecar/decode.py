"""Greedy TDT decoding on the CPU.

parakeet-mlx decodes one encoder frame at a time on the GPU and reads three
scalars back per step (token, confidence, duration). Each read is a full GPU
round trip, so a 30 s clip spends more time waiting on the GPU than computing.

The predictor (a 2-layer LSTM) and the joint's output layer are small enough
that the CPU does each step in microseconds with Accelerate, with no round
trips at all. The encoder stays on the GPU; only its joint projection, one
(frames x 640) matrix, crosses over.

The decoder is also resumable: `DecoderState` carries the predictor state and
the absolute frame position, so audio can be decoded in segments while the
user is still speaking and stitched without losing context.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import numpy as np


def _sigmoid(x: np.ndarray) -> np.ndarray:
    return 0.5 * (np.tanh(0.5 * x) + 1.0)  # stable, and one ufunc fewer


@dataclass
class DecoderState:
    """Everything needed to continue decoding where the last segment stopped."""

    # Predictor output for the last emitted token, and the LSTM state that
    # produced it. Both stay put across blank steps.
    pred_proj: np.ndarray | None = None
    lstm: list[tuple[np.ndarray, np.ndarray]] | None = None
    step: int = 0  # absolute encoder frame
    new_symbols: int = 0
    tokens: list[tuple[int, int, int]] = field(default_factory=list)  # (id, step, dur)


class FastTDT:
    """CPU mirror of a parakeet-mlx ParakeetTDT predictor + joint."""

    @staticmethod
    def supports(model: Any) -> bool:
        try:
            from parakeet_mlx.parakeet import ParakeetTDT
        except ImportError:
            return False
        return isinstance(model, ParakeetTDT)

    def __init__(self, model: Any) -> None:
        import mlx.core as mx

        def np32(a: Any) -> np.ndarray:
            return np.array(a.astype(mx.float32))

        self.vocabulary = model.vocabulary
        self.blank = len(model.vocabulary)
        self.durations = list(model.durations)
        self.max_symbols = model.max_symbols
        self.time_ratio = model.time_ratio

        pred = model.decoder.prediction
        embed = np32(pred["embed"].weight)
        layers = pred["dec_rnn"].lstm
        self.hidden = int(layers[0].Wh.shape[1])
        self.layers = []
        for i, layer in enumerate(layers):
            wx = np32(layer.Wx).T.copy()
            wh = np32(layer.Wh).T.copy()
            b = np32(layer.bias) if layer.bias is not None else np.zeros(wx.shape[1], np.float32)
            self.layers.append((wx, wh, b))
        # Layer 0's input projection only ever sees embedding rows, so fold it
        # into a lookup table: one row read instead of a matvec per token.
        wx0, _, b0 = self.layers[0]
        self.embed_gates = embed @ wx0 + b0
        self.blank_gates = b0.copy()  # blank-as-pad feeds a zero embedding

        joint = model.joint
        self.pred_w = np32(joint.pred.weight).T.copy()
        self.pred_b = np32(joint.pred.bias)
        out = joint.joint_net[-1]
        self.out_w = np32(out.weight).T.copy()
        self.out_b = np32(out.bias)
        name = type(joint.joint_net[0]).__name__.lower()
        self.activation = {
            "relu": lambda x: np.maximum(x, 0.0, out=x),
            "sigmoid": _sigmoid,
            "tanh": np.tanh,
        }[next(k for k in ("relu", "sigmoid", "tanh") if k in name)]

    # -- predictor ---------------------------------------------------------

    def _predict(self, token: int | None, lstm):
        gates = self.blank_gates if token is None else self.embed_gates[token]
        x = None
        state = []
        h_size = self.hidden
        for i, (wx, wh, b) in enumerate(self.layers):
            g = gates.copy() if i == 0 else x @ wx + b
            if lstm is not None:
                g += lstm[i][0] @ wh
            i_g = _sigmoid(g[:h_size])
            f_g = _sigmoid(g[h_size : 2 * h_size])
            c_g = np.tanh(g[2 * h_size : 3 * h_size])
            o_g = _sigmoid(g[3 * h_size :])
            cell = i_g * c_g if lstm is None else f_g * lstm[i][1] + i_g * c_g
            x = o_g * np.tanh(cell)
            state.append((x, cell))
        return x @ self.pred_w + self.pred_b, state

    # -- decoding ----------------------------------------------------------

    def decode(
        self, enc_proj: np.ndarray, base: int, stop: int, state: DecoderState
    ) -> DecoderState:
        """Decode frames [state.step, stop) where enc_proj[0] is frame `base`.

        `enc_proj` is the joint's encoder projection, float32 (frames, hidden).
        """
        if state.pred_proj is None:
            state.pred_proj, state.lstm = self._predict(None, None)
        blank = self.blank
        split = blank + 1
        durations = self.durations
        out_w, out_b, act = self.out_w, self.out_b, self.activation
        limit = min(stop, base + enc_proj.shape[0])
        pred_proj = state.pred_proj
        step, new_symbols = state.step, state.new_symbols

        while step < limit:
            logits = act(enc_proj[step - base] + pred_proj) @ out_w + out_b
            token = int(np.argmax(logits[:split]))
            dur = durations[int(np.argmax(logits[split:]))]
            if token != blank:
                state.tokens.append((token, step, dur))
                # The predictor only moves when a real token is emitted.
                pred_proj, state.lstm = self._predict(token, state.lstm)
            step += dur
            new_symbols += 1
            if dur != 0:
                new_symbols = 0
            elif self.max_symbols is not None and self.max_symbols <= new_symbols:
                step += 1
                new_symbols = 0

        state.pred_proj = pred_proj
        state.step, state.new_symbols = step, new_symbols
        return state

    def text(self, state: DecoderState) -> str:
        from parakeet_mlx import tokenizer
        from parakeet_mlx.alignment import (
            AlignedToken,
            sentences_to_result,
            tokens_to_sentences,
        )

        if not state.tokens:
            return ""
        tokens = [
            AlignedToken(
                tok,
                start=step * self.time_ratio,
                duration=dur * self.time_ratio,
                text=tokenizer.decode([tok], self.vocabulary),
            )
            for tok, step, dur in state.tokens
        ]
        return sentences_to_result(tokens_to_sentences(tokens)).text.strip()
