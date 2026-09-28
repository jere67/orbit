"""Topics: which items are about the same thing, so the week board and the
agenda can show one row per topic ("Chem 101 | Lab | Quiz") instead of repeats.

Nothing about a person's topics is written in code, and nothing assumes how
titles are written: not where a topic sits in a title, nor which punctuation
sets it off. Code only proposes candidates - runs of words several titles
share anywhere, and runs spelled almost the same way - and the model judges
each one with a small question it answers reliably: do 'Chem 101' and
'Chem 240' belong to the same thing (no, so 'Chem' is too broad)? Do
'Chem 101' and 'Lab for Chem 101' (yes, so 'Chem 101' is a topic)? Is
'Chme 101' a typo of 'Chem 101'? Each verdict is voted and cached in the graph, so the model is
asked once per question. Without a verdict (AI off, or the model has not
answered yet) a structural fallback keeps the obvious groups.
"""

import re;
import hashlib;
import unicodedata;
import from difflib { SequenceMatcher }
import from .config { ai_enabled, ai_status }
import from .llm { orbit_llm }
import from .items { list_items }
import from .model { TitleTopic, TopicMap }


"""How alike two names must be (0-1) before the model is asked whether they
are the same name; below this they are never merged."""
glob NEAR_RATIO: float = 0.8;


"""Bump to re-ask the model about every candidate (after changing a prompt)."""
glob TOPIC_VERSION: str = "5";


"""How many of a candidate's other examples the model compares with its first
before calling the candidate one subject."""
glob MAX_PAIRS: int = 2;


"""The model sees at most this many of a candidate's titles when judging what
its shared words are."""
glob MAX_LABEL_ITEMS: int = 4;


"""One word of a title: its comparable form (lowercase letters and digits only,
so 'Chem:' and 'chem' match), where its letters start and end in the title, and
where the whole word, punctuation included, starts and ends ('(TA)')."""
obj Word {
    has key: str,
        start: int,
        end: int,
        outer_start: int,
        outer_end: int;
}


"""The words of a title that carry letters or digits, in order; bare
punctuation such as '-' or '|' is not a word."""
def _words(title: str) -> list[Word] {
    out: list[Word] = [];
    for m in re.finditer(r"\S+", title) {
        raw = m.group(0);
        spots = [i for i in range(len(raw)) if raw[i].isalnum()];
        if spots {
            key = "".join([c for c in raw.lower() if c.isalnum()]);
            out.append(
                Word(
                    key=key, start=m.start() + spots[0], end=m.start() + spots[-1] + 1,
                    outer_start=m.start(), outer_end=m.end()
                )
            );
        }
    }
    return out;
}


def _keys(words: list[Word]) -> tuple[str, ...] {
    return tuple([w.key for w in words]);
}


"""Where `run` first occurs as consecutive words in `keys`, or -1."""
def _find(keys: tuple[str, ...], run: tuple[str, ...]) -> int {
    n = len(run);
    i = 0;
    while i + n <= len(keys) {
        if keys[i:i + n] == run {
            return i;
        }
        i += 1;
    }
    return -1;
}


"""True for a character that only joins words - a space, dash, colon, bar,
slash, and the like, by Unicode category - rather than one that belongs to the
text beside it, such as a bracket or a quote."""
def _is_joiner(c: str) -> bool {
    cat = unicodedata.category(c);
    return cat.startswith("Z") or cat in ["Cc", "Pc", "Pd", "Po", "Sm"];
}


"""Text with its whitespace collapsed, joining characters trimmed from both
ends, a bracket left unmatched at either end dropped ('Lab)' -> 'Lab'), and one
pair of brackets around the whole of it removed ('(Lab)' -> 'Lab')."""
def _clean(text: str) -> str {
    s = " ".join(text.split());
    while s and _is_joiner(s[0]) {
        s = s[1:];
    }
    while s and _is_joiner(s[-1]) {
        s = s[:-1];
    }
    if not s {
        return s;
    }
    opens = len([c for c in s if unicodedata.category(c) == "Ps"]);
    closes = len([c for c in s if unicodedata.category(c) == "Pe"]);
    if unicodedata.category(s[0]) == "Ps" and opens > closes {
        return _clean(s[1:]);
    }
    if unicodedata.category(s[-1]) == "Pe" and closes > opens {
        return _clean(s[:-1]);
    }
    inner = s[1:-1];
    wrapped = len(s) >= 2 and unicodedata.category(s[0]) == "Ps" and unicodedata.category(s[-1]) == "Pe";
    if wrapped and not any([unicodedata.category(c) in ["Ps", "Pe"] for c in inner]) {
        return _clean(inner);
    }
    return s;
}


"""A title split around n words starting at word `at`: those words as written,
and the rest of the title ('Chem 101 - Lab', 0, 2 -> 'Chem 101', 'Lab';
'Lab for Chem 101', 2, 2 -> 'Chem 101', 'Lab for')."""
def _split(title: str, words: list[Word], at: int, n: int) -> tuple[str, str] {
    first = words[at];
    last = words[at + n - 1];
    head = _clean(title[first.outer_start:last.outer_end]);
    rest = _clean(title[:first.outer_start] + " " + title[last.outer_end:]);
    return (head, rest);
}


"""True when the title marks where its first n words end with punctuation
('Recruiting: Acme OA', 'Chem 101 - Lab'), not just a space."""
def _set_off(title: str, words: list[Word], n: int) -> bool {
    if n >= len(words) {
        return False;
    }
    return any([_is_joiner(c) and not c.isspace() for c in title[words[n - 1].end:words[n].start]]);
}


"""A run of consecutive words that two or more titles share, anywhere in them:
the model decides whether it names one subject. `examples` are how its titles
read at a glance: each title, or the narrower candidate it falls under
('Chem 101' for 'Chem 101 - Lab' when the candidate is 'Chem')."""
obj Candidate {
    has keys: tuple[str, ...],
        name: str,
        titles: list[str] = [],
        examples: list[str] = [];
}


"""Every run of consecutive words that some pair of titles has in common."""
def _shared_runs(parsed: list[tuple[tuple[str, ...], str]]) -> set[tuple[str, ...]] {
    runs: set[tuple[str, ...]] = set();
    i = 0;
    while i < len(parsed) {
        a = parsed[i][0];
        j = i + 1;
        while j < len(parsed) {
            b = parsed[j][0];
            for x in range(len(a)) {
                for y in range(len(b)) {
                    k = 0;
                    while x + k < len(a) and y + k < len(b) and a[x + k] == b[y + k] {
                        k += 1;
                        runs.add(a[x:x + k]);
                    }
                }
            }
            j += 1;
        }
        i += 1;
    }
    return runs;
}


"""The candidates among the titles, broadest first (fewest words, then most
titles). Only the longest run is kept for each set of titles ('Chem' and
'Chem 101' appearing in exactly the same titles leave only 'Chem 101')."""
def _candidates(titles: list[str]) -> list[Candidate] {
    parsed = [(_keys(_words(t)), t) for t in titles];
    best: dict[str, Candidate] = {};
    for run in _shared_runs(parsed) {
        members = [t for (k, t) in parsed if _find(k, run) >= 0];
        if len(members) < 2 {
            continue;
        }
        key = "\n".join(members);
        if key not in best or len(run) > len(best[key].keys) {
            best[key] = Candidate(keys=run, name="", titles=members);
        }
    }
    cands = sorted(
        best.values(),
        key=lambda (c: Candidate) -> tuple[int, int, str] { return (len(c.keys), -len(c.titles), " ".join(c.keys)); }
    );
    for cand in cands {
        cand.name = _display_name(cand);
    }
    for cand in cands {
        for t in cand.titles {
            narrower = [
                c for c in cands
                if len(c.keys) > len(cand.keys) and _find(c.keys, cand.keys) >= 0 and t in c.titles
            ];
            example = narrower[0].name if narrower else t;
            if example not in cand.examples {
                cand.examples.append(example);
            }
        }
    }
    return cands;
}


"""How a candidate is written: as the title that is exactly the candidate if
there is one, else as most of its titles write those words."""
def _display_name(cand: Candidate) -> str {
    n = len(cand.keys);
    heads: list[str] = [];
    for t in cand.titles {
        words = _words(t);
        (head, rest) = _split(t, words, _find(_keys(words), cand.keys), n);
        if not rest {
            return head;
        }
        heads.append(head);
    }
    return max(heads, key=lambda (h: str) -> int { return heads.count(h); });
}


"""The model's judgement of two items that share some words. A small model
judges a single pair far better than a whole list: shown 'Chem' with
['Chem 101', 'Chem 240'] it calls them one subject, but asked about the pair
'Chem 101' / 'Chem 240' it answers correctly."""
enum SameGroup {
    DIFFERENT_GROUPS,
    SAME_GROUP
}

def same_group(first: str, second: str) -> SameGroup by orbit_llm();
sem same_group.first = "An item from one person's planner";
sem same_group.second = "Another item from the same planner";
sem same_group = """Decide whether the two items belong to the same one course, project, club, company, or activity.
SAME_GROUP: both are parts of the same one thing (e.g. 'Chem 101 - Lab' and 'Chem 101: Problem Set 3'; 'Acme' and 'Acme Interview').
DIFFERENT_GROUPS: they are about different things, even if they share words (e.g. 'Chem 101' and 'Chem 240' are two different courses; 'Call mom' and 'Call the bank'; 'Chem 101 - Lab' and 'Bio 110 - Lab').""";


"""The model's judgement of the shared words themselves. Pairwise, a small
model calls two items that share a kind of event ('Chem 101 - Staff Meeting',
'Book club - Meeting') the same group; asked what 'Meeting' is, it answers
correctly. So a single shared word that is not at the start of every title
it appears in must pass this question too. (Longer runs such as 'Chem 101'
skip it: they are rarely general words, and the model misjudges course codes
here.)"""
enum LabelKind {
    GENERAL_WORD,
    SPECIFIC_NAME
}

def label_kind(label: str, items: list[str]) -> LabelKind by orbit_llm();
sem label_kind.label = "Words that several items in one person's planner share";
sem label_kind.items = "Some of the items that contain the label";
sem label_kind = """Decide what the label is in these items.
SPECIFIC_NAME: the name of one particular course, project, team, club, company, organization, or person - often a code, an acronym, or a proper noun (e.g. 'Chem 101', 'Acme', 'Book club', 'Robotics Lab').
GENERAL_WORD: an ordinary word or category that many unrelated things could share - a kind of event or task, a subject area or department, a role, or a bare number (e.g. 'Meeting', 'Lab', 'Exam', 'Homework', 'Chem', 'TA', '101').""";


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
def _vote(ask: Callable[[], SameGroup | NameMatch | LabelKind]) -> str {
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


"""Answers to candidate questions: cached ones always, plus the model's answer
to up to `budget` new ones, which are then cached. A question left without an
answer gets '' (so its fallback applies) and marks the pass `pending`;
`answered` counts the new verdicts actually cached."""
obj Verdicts {
    has memos: dict[str, TopicMemo] = {},
        budget: int = 0,
        pending: bool = False,
        answered: int = 0,
        used: set[str] = set();

    def get(question: str, ask: Callable[[], SameGroup | NameMatch | LabelKind]) -> str {
        key = hashlib.md5((TOPIC_VERSION + "|" + ai_status() + "|" + question).encode("utf-8")).hexdigest()[:16];
        self.used.add(key);
        if key in self.memos {
            return self.memos[key].verdict;
        }
        if self.budget <= 0 {
            self.pending = True;
            return "";
        }
        self.budget -= 1;
        verdict = _vote(ask);
        if verdict {
            memo = TopicMemo(key=key, verdict=verdict);
            root ++> memo;
            self.memos[key] = memo;
            self.answered += 1;
        }
        return verdict;
    }
}


"""Whether a candidate names one subject.

A single word that is not at the start of every title it appears in must first
be a SPECIFIC_NAME to the model (`labeled`). Then the model compares the first
example with the next few (`grouped`): one DIFFERENT_GROUPS verdict makes the
candidate too broad, SAME_GROUP for all makes it a subject. Without the
verdicts it needs, the structure of its titles decides - one of them is exactly
the candidate ('Chem 101' for 'Chem 101 Lab'), or every title starts with it
and sets it off with punctuation ('Recruiting: Acme OA', 'Recruiting - Globex')."""
def _is_subject(cand: Candidate, grouped: Callable[[str, str], str], labeled: Callable[[str, list[str]], str]) -> bool {
    parsed = [(t, _words(t)) for t in cand.titles];
    n = len(cand.keys);
    word_lists = [w for (_t, w) in parsed];
    exact = any([_keys(w) == cand.keys for w in word_lists]);
    leading = all([_find(_keys(w), cand.keys) == 0 for w in word_lists]);
    structural = exact or (leading and all([_set_off(t, w, n) for (t, w) in parsed]));
    if not leading and n == 1 {
        kind = labeled(cand.name, cand.titles[:MAX_LABEL_ITEMS]);
        if kind == LabelKind.GENERAL_WORD.name {
            return False;
        }
        if kind != LabelKind.SPECIFIC_NAME.name {
            return structural;
        }
    }
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
    return structural;
}


"""The candidates that name one subject, broadest first. A candidate that
contains a subject already chosen is never needed (its titles already join
that subject), so the model is not asked about it."""
def _subjects(
    cands: list[Candidate], grouped: Callable[[str, str], str], labeled: Callable[[str, list[str]], str]
) -> list[Candidate] {
    out: list[Candidate] = [];
    for c in cands {
        if any([_find(c.keys, s.keys) >= 0 for s in out]) {
            continue;
        }
        if _is_subject(c, grouped, labeled) {
            out.append(c);
        }
    }
    return out;
}


"""Each title's topic and the part of it that is its own detail.

`grouped(item, other)` (a SameGroup), `labeled(words, items)` (a LabelKind),
and `same(name, other)` (a NameMatch) return a verdict name, or '' when there
is none. A title joins the broadest
candidate it contains that names one subject; failing that, a subject whose
name some of its words nearly spell, when the model says the names match.
Titles with no topic are their own topic with no detail."""
def _topic_map(
    titles: list[str],
    grouped: Callable[[str, str], str],
    labeled: Callable[[str, list[str]], str],
    same: Callable[[str, str], str]
) -> list[TitleTopic] {
    uniq = sorted(set([t for t in titles if t.strip()]));
    subjects = _subjects(_candidates(uniq), grouped, labeled);
    out: list[TitleTopic] = [];
    for t in uniq {
        words = _words(t);
        keys = _keys(words);
        found = _placed(t, words, keys, subjects, same);
        out.append(found if found is not None else TitleTopic(title=t, topic=t, part=""));
    }
    return out;
}


"""The title's place under a subject, or None: a subject whose words it
contains, else one whose name some of its words nearly spell ('Chme 101' for
'Chem 101') when the model says the two are the same name."""
def _placed(
    t: str, words: list[Word], keys: tuple[str, ...], subjects: list[Candidate], same: Callable[[str, str], str]
) -> TitleTopic | None {
    for c in subjects {
        at = _find(keys, c.keys);
        if at >= 0 {
            return TitleTopic(title=t, topic=c.name, part=_split(t, words, at, len(c.keys))[1]);
        }
    }
    for c in subjects {
        n = len(c.keys);
        theirs = " ".join(c.keys);
        at = 0;
        while at + n <= len(keys) {
            mine = " ".join(keys[at:at + n]);
            if SequenceMatcher(None, mine, theirs).ratio() >= NEAR_RATIO {
                (head, rest) = _split(t, words, at, n);
                if same(c.name, head) == NameMatch.SAME_NAME.name {
                    return TitleTopic(title=t, topic=c.name, part=rest);
                }
            }
            at += 1;
        }
    }
    return None;
}


"""How many new questions one `title_topics` call may ask the model. Each takes
seconds on a local model, so a first pass is spread over several short calls
rather than one that holds a server worker for minutes."""
glob ASKS_PER_CALL: int = 4;


"""Every item title's topic and detail, e.g. 'Chem 101 - Lab' -> topic 'Chem 101',
part 'Lab'. With `ask_model` the model answers up to ASKS_PER_CALL questions it
has not judged yet, and `pending` says whether more remain (call again to
refine); without it only cached verdicts are used, so the call is instant and
safe to make on every render."""
def:pub title_topics(ask_model: bool = False) -> TopicMap {
    all_memos = [root-->][?:TopicMemo];
    memos = {m.key: m for m in all_memos};
    budget = ASKS_PER_CALL if ask_model and ai_enabled() else 0;
    verdicts = Verdicts(memos=memos, budget=budget);
    grouped = lambda (item: str, other: str) -> str {
        pair = sorted([item, other]);
        return verdicts.get(
            "group|" + pair[0] + "|" + pair[1],
            lambda { same_group(pair[0], pair[1]); }
        );
    };
    labeled = lambda (label: str, items: list[str]) -> str {
        return verdicts.get(
            "label|" + label + "|" + "|".join(items),
            lambda { label_kind(label, items); }
        );
    };
    same = lambda (name: str, other: str) -> str {
        return verdicts.get(
            "match|" + name + "|" + other,
            lambda { name_match(name, other); }
        );
    };
    topics = _topic_map([it.title for it in list_items()], grouped, labeled, same);
    # Only a pass that answered everything knows which cached verdicts are stale.
    if budget > 0 and not verdicts.pending {
        for m in all_memos {
            if m.key not in verdicts.used {
                del m;
            }
        }
    }
    # Pending only when this call made progress, so a model that keeps failing
    # does not keep the client asking.
    return TopicMap(topics=topics, pending=verdicts.pending and verdicts.answered > 0);
}
