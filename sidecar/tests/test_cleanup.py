from talk_sidecar.cleanup import clean
from talk_sidecar.config import DEFAULTS

CFG = DEFAULTS["cleanup"]


def c(text: str) -> str:
    return clean(text, CFG)


def test_removes_fillers_without_orphaning_commas():
    assert c("Hey, um, so I was thinking.") == "Hey, so I was thinking."
    assert c("Um, ship it.") == "Ship it."
    assert c("that is, uh, fine") == "That is, fine"


def test_keeps_words_that_merely_contain_a_filler():
    assert c("the umbrella is here") == "The umbrella is here"
    assert c("ahead of time") == "Ahead of time"
    assert c("summer erm plans") == "Summer plans"


def test_collapses_stutters():
    assert c("we should. We should ship the app.") == "We should ship the app."
    assert c("the the file") == "The file"
    assert c("I want, I want, I want that") == "I want that"


def test_spoken_punctuation():
    assert c("hello comma world period") == "Hello, world."
    assert c("first line new line second line") == "First line\nSecond line"
    assert c("done new paragraph next") == "Done\n\nNext"
    assert c("really question mark") == "Really?"


def test_capitalization_and_i():
    assert c("i think i'm done") == "I think I'm done"
    assert c("one. two. three.") == "One. Two. Three."


def test_vocabulary_substitution():
    assert c("open claude code") == "Open Claude Code"
    assert c("push to git hub") == "Push to GitHub"


def test_decimals_survive():
    assert "3.5" in c("version 3.5 is out")


def test_empty_and_whitespace():
    assert c("") == ""
    assert c("   ") == ""


def test_disabled_passes_text_through():
    assert clean("um, hello", {"enabled": False}) == "um, hello"
