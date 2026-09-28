"""Topics: which items are about the same thing, so the week board and the
agenda can show one row per topic ("EECS 482 | LEC | P1") instead of repeats.

Nothing about a person's topics is written in code. Code only proposes
candidates from the shape of the titles - leading words several titles share,
and leading words that are nearly the same name - and the model judges each
one with a small question it answers reliably: do 'EECS 449' and 'EECS 482'
belong to the same thing (no, so 'EECS' is too broad)? Do 'EECS 482' and
'EECS 482 - P1' (yes, so 'EECS 482' is a topic)? Is 'Chme 101' a typo of
'Chem 101'? Each verdict is voted and cached in the graph, so the model is
asked once per question. Without a verdict (AI off, or the model has not
answered yet) a structural fallback keeps the obvious groups.
"""

import re;
import hashlib;
import from difflib { SequenceMatcher }
import from .config { ai_enabled, ai_status }
import from .llm { orbit_llm }
import from .items { list_items }
import from .model { TitleTopic }


"""Characters that separate a title's subject from its detail ("X - Y", "X: Y")."""
glob SEPARATORS: str = " -–—:|,·/";


"""How alike two leading names must be (0-1) before the model is asked whether
they are the same name; below this they are never merged."""
glob NEAR_RATIO: float = 0.8;


"""Bump to re-ask the model about every candidate (after changing a prompt)."""
glob TOPIC_VERSION: str = "4";


"""How many of a candidate's other examples the model compares with its first
before calling the candidate one subject."""
glob MAX_PAIRS: int = 2;


"""One word of a title: its comparable form and where its text starts and ends
in the title (leading and trailing punctuation excluded)."""
obj Word {
    has key: str,
        start: int,
        end: int;
}


"""The words of a title that carry meaning - lowercased, with punctuation
trimmed, and bare separators like '-' dropped."""
def _words(title: str) -> list[Word] {
    trim = SEPARATORS + ".;!?\"'";
    out: list[Word] = [];
    for m in re.finditer(r"\S+", title) {
        raw = m.group(0);
        key = raw.strip(trim);
        if key {
            lead = len(raw) - len(raw.lstrip(trim));
            out.append(Word(key=key.lower(), start=m.start() + lead, end=m.start() + lead + len(key)));
        }
    }
    return out;
}


def _keys(words: list[Word]) -> tuple[str, ...] {
    return tuple([w.key for w in words]);
}


"""The title's text after its first n meaningful words, with the separators
that joined it to the subject trimmed ('EECS 482 - P1', 2 -> 'P1')."""
def _rest(title: str, words: list[Word], n: int) -> str {
    if n >= len(words) {
        return "";
    }
    return title[words[n - 1].end:].strip().lstrip(SEPARATORS).strip();
}


"""The title's first n meaningful words as written ('AIMS: Social Media', 1 -> 'AIMS')."""
def _head(title: str, words: list[Word], n: int) -> str {
    return title[:words[n - 1].end].strip();
}


"""True when the title marks where its subject ends right after n words - it
has nothing more, or a separator follows ('FIN 302 - LEC', 'Recruiting: OA')."""
def _breaks_after(title: str, words: list[Word], n: int) -> bool {
    if n >= len(words) {
        return True;
    }
    gap = title[words[n - 1].end:words[n].start];
    return any([c in gap for c in "-–—:|/"]);
}


"""A group of leading words that two or more titles share: the model decides
whether it names one subject. `examples` are how its titles read at a glance:
each title, or the narrower candidate it falls under ('EECS 482' for
'EECS 482 - P1' when the candidate is 'EECS')."""
obj Candidate {
    has keys: tuple[str, ...],
        name: str,
        titles: list[str] = [],
        examples: list[str] = [];
}


"""Every run of leading words that at least two titles share, keeping only the
longest run for each set of titles ('FIN' and 'FIN 302' start the same titles,
so only 'FIN 302' is a candidate). Sorting the titles by their words puts every
shared prefix between some pair of neighbours, so comparing neighbours finds
them all."""
def _shared_prefixes(titles: list[str]) -> list[Candidate] {
    parsed = sorted([(_keys(_words(t)), t) for t in titles]);
    found: dict[tuple[str, ...], Candidate] = {};
    i = 1;
    while i < len(parsed) {
        (a, _ta) = parsed[i - 1];
        (b, _tb) = parsed[i];
        n = 0;
        while n < len(a) and n < len(b) and a[n] == b[n] {
            n += 1;
        }
        j = 1;
        while j <= n {
            found[a[:j]] = Candidate(keys=a[:j], name="");
            j += 1;
        }
        i += 1;
    }
    for (keys, cand) in found.items() {
        for (k, t) in parsed {
            if k[:len(keys)] == keys {
                cand.titles.append(t);
            }
        }
        cand.name = _display_name(cand.titles, len(keys));
    }
    longest: dict[str, Candidate] = {};
    for cand in found.values() {
        members = "\n".join(cand.titles);
        if members not in longest or len(cand.keys) > len(longest[members].keys) {
            longest[members] = cand;
        }
    }
    cands = sorted(longest.values(), key=lambda (c: Candidate) -> int { return len(c.keys); });
    for cand in cands {
        n = len(cand.keys);
        for t in cand.titles {
            keys = _keys(_words(t));
            narrower = [c for c in cands if len(c.keys) > n and keys[:len(c.keys)] == c.keys];
            example = narrower[0].name if narrower else t;
            if example not in cand.examples {
                cand.examples.append(example);
            }
        }
    }
    return cands;
}


"""How a candidate is written: as the title that is exactly the candidate if
there is one ('EECS 482'), else as the most titles write its words."""
def _display_name(titles: list[str], n: int) -> str {
    heads: list[str] = [];
    for t in titles {
        words = _words(t);
        if len(words) == n {
            return _head(t, words, n);
        }
        heads.append(_head(t, words, n));
    }
    return max(heads, key=lambda (h: str) -> int { return heads.count(h); });
}


"""The model's judgement of two items that start with the same words. A small
model judges a single pair far better than a whole list: shown 'EECS' with
['EECS 449', 'EECS 482'] it calls them one subject, but asked about the pair
'EECS 449' / 'EECS 482' it answers correctly."""
enum SameGroup {
    DIFFERENT_GROUPS,
    SAME_GROUP
}

def same_group(first: str, second: str) -> SameGroup by orbit_llm();
sem same_group.first = "An item from one person's planner";
sem same_group.second = "Another item from the same planner";
sem same_group = """Decide whether the two items belong to the same one course, project, club, company, or activity.
SAME_GROUP: both are parts of the same one thing (e.g. 'Chem 101 - Lab' and 'Chem 101: Problem Set 3'; 'Acme' and 'Acme Interview').
DIFFERENT_GROUPS: they are about different things, even if they start alike (e.g. 'Chem 101' and 'Chem 240' are two different courses; 'Call mom' and 'Call the bank').""";


"""The model's judgement of two nearly identical names."""
enum NameMatch {
    SAME_NAME,
    DIFFERENT_NAMES
}

def name_match(first: str, second: str) -> NameMatch by orbit_llm();
sem name_match.first = "A name from one person's planner";
sem name_match.second = "Another name from the same planner, spelled almost the same way";
sem name_match = """Decide whether the two names refer to the same thing.
SAME_NAME: one is a typo or variant spelling of the other (e.g. 'Chem 101' and 'Chme 101', 'Book club' and 'Bookclub').
DIFFERENT_NAMES: they are different things that only look alike, such as a different number (e.g. 'Chem 101' and 'Chem 102', 'Room 4B' and 'Room 4C').""";


"""A cached model verdict on one candidate question."""
node TopicMemo {
    has key: str,
        verdict: str = "";
}


"""The model's verdict by majority of up to three asks - a small local model is
not deterministic even at temperature 0, and a verdict is cached for good.
'' when every call fails."""
def _vote(ask: Callable[[], SameGroup | NameMatch]) -> str {
    votes: list[str] = [];
    attempts = 0;
    while attempts < 3 {
        attempts += 1;
        try {
            votes.append(ask().name);
        } except Exception as e {
            _ = e;
            continue;
        }
        if votes.count(votes[-1]) >= 2 {
            return votes[-1];
        }
    }
    return votes[0] if votes else "";
}


"""Answers to candidate questions: cached ones always, and - when `ask_model`
is set and AI is on - the model's answer to the rest, which are then cached.
Questions with no answer are left out, so their fallback applies."""
obj Verdicts {
    has memos: dict[str, TopicMemo] = {},
        ask_model: bool = False,
        used: set[str] = set();

    def get(question: str, ask: Callable[[], SameGroup | NameMatch]) -> str {
        key = hashlib.md5((TOPIC_VERSION + "|" + ai_status() + "|" + question).encode("utf-8")).hexdigest()[:16];
        self.used.add(key);
        if key in self.memos {
            return self.memos[key].verdict;
        }
        if not self.ask_model {
            return "";
        }
        verdict = _vote(ask);
        if verdict {
            memo = TopicMemo(key=key, verdict=verdict);
            root ++> memo;
            self.memos[key] = memo;
        }
        return verdict;
    }
}


"""Whether a candidate names one subject. The model compares its first example
with the next few: one DIFFERENT_GROUPS verdict makes it too broad, SAME_GROUP
for all makes it a subject. Without every verdict, the structure of its titles
decides - one of them is exactly the candidate ('AIMS' for 'AIMS Meeting'), or
every title separates the candidate from its detail ('Recruiting: A',
'Recruiting - B')."""
def _is_subject(cand: Candidate, grouped: Callable[[str, str], str]) -> bool {
    others = cand.examples[1:1 + MAX_PAIRS];
    agreed = 0;
    for other in others {
        verdict = grouped(cand.examples[0], other);
        if verdict == SameGroup.DIFFERENT_GROUPS.name {
            return False;
        }
        if verdict == SameGroup.SAME_GROUP.name {
            agreed += 1;
        }
    }
    if others and agreed == len(others) {
        return True;
    }
    n = len(cand.keys);
    breaks = [_breaks_after(t, _words(t), n) for t in cand.titles];
    exact = [len(_words(t)) == n for t in cand.titles];
    return any(exact) or all(breaks);
}


"""The candidates that name one subject, broadest first. A candidate under a
broader subject is never needed (its titles already join the broader one), so
the model is not asked about it."""
def _subjects(cands: list[Candidate], grouped: Callable[[str, str], str]) -> list[Candidate] {
    out: list[Candidate] = [];
    for c in cands {
        if any([c.keys[:len(s.keys)] == s.keys for s in out]) {
            continue;
        }
        if _is_subject(c, grouped) {
            out.append(c);
        }
    }
    return out;
}


"""Each title's topic and the part of it that is its own detail.

`grouped(item, other)` (a SameGroup) and `same(name, other)` (a NameMatch)
return a verdict name, or '' when there is none. A title joins the broadest shared candidate that names one subject;
failing that, a candidate whose name it nearly shares, when the names match.
Titles with no topic are their own topic with no detail."""
def _topic_map(titles: list[str], grouped: Callable[[str, str], str], same: Callable[[str, str], str]) -> list[TitleTopic] {
    uniq = sorted(set([t for t in titles if t.strip()]));
    subjects = _subjects(_shared_prefixes(uniq), grouped);
    out: list[TitleTopic] = [];
    for t in uniq {
        words = _words(t);
        keys = _keys(words);
        placed = False;
        for c in subjects {
            if keys[:len(c.keys)] == c.keys {
                out.append(TitleTopic(title=t, topic=c.name, part=_rest(t, words, len(c.keys))));
                placed = True;
                break;
            }
        }
        if placed {
            continue;
        }
        for c in subjects {
            n = len(c.keys);
            if n > len(keys) {
                continue;
            }
            mine = " ".join(keys[:n]);
            theirs = " ".join(c.keys);
            if mine == theirs or SequenceMatcher(None, mine, theirs).ratio() < NEAR_RATIO {
                continue;
            }
            if same(c.name, _head(t, words, n)) == NameMatch.SAME_NAME.name {
                out.append(TitleTopic(title=t, topic=c.name, part=_rest(t, words, n)));
                placed = True;
                break;
            }
        }
        if not placed {
            out.append(TitleTopic(title=t, topic=t, part=""));
        }
    }
    return out;
}


"""Every item title's topic and detail, e.g. 'EECS 482 - P1' -> topic 'EECS 482',
part 'P1'. With `ask_model` the model is asked about candidates it has not
judged yet (seconds each on a local model); without it only cached verdicts
are used, so the call is instant and safe to make on every render."""
def:pub title_topics(ask_model: bool = False) -> list[TitleTopic] {
    all_memos = [root-->][?:TopicMemo];
    memos = {m.key: m for m in all_memos};
    verdicts = Verdicts(memos=memos, ask_model=ask_model and ai_enabled());
    grouped = lambda (item: str, other: str) -> str {
        pair = sorted([item, other]);
        return verdicts.get(
            "group|" + pair[0] + "|" + pair[1],
            lambda { same_group(pair[0], pair[1]); }
        );
    };
    same = lambda (name: str, other: str) -> str {
        return verdicts.get(
            "match|" + name + "|" + other,
            lambda { name_match(name, other); }
        );
    };
    topics = _topic_map([it.title for it in list_items()], grouped, same);
    if verdicts.ask_model {
        for m in all_memos {
            if m.key not in verdicts.used {
                del m;
            }
        }
    }
    return topics;
}
