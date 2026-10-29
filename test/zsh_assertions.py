#!/usr/bin/env python3
"""Reject inert top-level assertions in literal Zsh programs in BATS tests.

This is a static guard, not a shell parser: dynamic programs, heredoc-fed Zsh,
and checks inside function/control-flow bodies still need review. We inspect
literal run_zsh and zsh -c arguments, also when nested in bash -c or Zsh code.
Quoted words are decoded without expansion or execution. Source line numbers
survive escaped quotes and backslash-newline continuations.
"""

import re
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Word:
    value: str
    lines: list
    quoted: bool = False


def words(text, lines):
    """Read shell words, retaining literal quoted arguments and source lines."""
    index = 0
    heredocs = []
    while index < len(text):
        char = text[index]
        if char == "\n" and heredocs:
            index += 1
            # Heredoc contents are data, even when they contain unmatched
            # quotes. Resume tokenizing only after every queued delimiter.
            for delimiter, strip_tabs in heredocs:
                while index < len(text):
                    end = text.find("\n", index)
                    if end < 0:
                        end = len(text)
                    body_line = text[index:end]
                    index = end + 1
                    if (body_line.lstrip("\t") if strip_tabs else body_line) == delimiter:
                        break
            heredocs = []
            continue
        if text.startswith("<<<", index):
            index += 3
            continue
        if text.startswith("((", index):
            # Arithmetic shifts are not heredoc redirections. These words
            # cannot introduce literal shell -c arguments.
            end = text.find("))", index + 2)
            index = len(text) if end < 0 else end + 2
            continue
        if text.startswith("<<", index):
            index += 2
            strip_tabs = text[index:index + 1] == "-"
            index += strip_tabs
            while index < len(text) and text[index] in " \t":
                index += 1
            delimiter, quote = [], None
            while index < len(text):
                char = text[index]
                if quote is None and (char.isspace() or char in ";|&(){}<>"):
                    break
                if char in "'\"" and (quote is None or quote == char):
                    quote = None if quote == char else char
                elif char == "\\" and quote != "'" and index + 1 < len(text):
                    index += 1
                    delimiter.append(text[index])
                else:
                    delimiter.append(char)
                index += 1
            if delimiter:
                heredocs.append(("".join(delimiter), strip_tabs))
            continue
        if char.isspace() or char in ";|&(){}<>":
            index += 1
            continue
        if char == "#":
            index = text.find("\n", index)
            if index < 0:
                return
            continue
        value, where = [], []
        quote = None
        quoted = False
        while index < len(text):
            char = text[index]
            if quote is None and (char.isspace() or char in ";|&(){}<>"):
                break
            if char in "'\"" and (quote is None or quote == char):
                quoted = True
                quote = None if quote == char else char
                index += 1
                continue
            if char == "\\" and quote != "'" and index + 1 < len(text):
                following = text[index + 1]
                if following == "\n":
                    index += 2
                    continue
                if quote is None or following in '$`"\\':
                    index += 1
                    char = text[index]
            value.append(char)
            where.append(lines[index])
            index += 1
        if value or quoted:
            yield Word("".join(value), where, quoted)


def programs(text, lines, depth=0):
    """Find literal programs; recursive shell -c strings cover nested quoting."""
    if depth > 5:
        return
    tokens = list(words(text, lines))
    for index, token in enumerate(tokens):
        name = token.value.rsplit("/", 1)[-1]
        if name == "run_zsh" and not token.quoted:
            argument = index + 1
            language = "zsh"
        elif name in ("zsh", "bash", "sh"):
            argument = index + 1
            language = name
            while argument < len(tokens) and re.fullmatch(r"-[A-Za-z]+", tokens[argument].value):
                flags = tokens[argument].value[1:]
                argument += 1
                if "c" in flags:
                    break
            else:
                continue
        else:
            continue
        if argument >= len(tokens):
            continue
        program = tokens[argument]
        # Variables and substitutions cannot be checked without executing code.
        if not program.quoted or not program.lines or program.value.startswith(("$", "`")):
            continue
        if language == "zsh":
            yield program
        yield from programs(program.value, program.lines, depth + 1)


def statements(program):
    """Join continuations and split top-level lines/semicolons, outside quotes."""
    text = program.value
    buffer, locations = [], []
    quote = None
    bracket = 0
    parens = 0
    index = 0
    while index < len(text):
        char = text[index]
        pair = text[index:index + 2]
        if char == "\\" and quote != "'" and index + 1 < len(text):
            if text[index + 1] == "\n":
                index += 2
                continue
            buffer.extend(text[index:index + 2])
            locations.extend(program.lines[index:index + 2])
            index += 2
            continue
        if char in "'\"":
            if quote is None:
                quote = char
            elif quote == char:
                quote = None
        if quote is None:
            if char == "#" and (not buffer or buffer[-1].isspace()):
                end = text.find("\n", index)
                index = len(text) if end < 0 else end
                continue
            if pair == "[[":
                bracket += 1
            elif pair == "]]" and bracket:
                bracket -= 1
            if not bracket:
                if char == "(":
                    parens += 1
                elif char == ")" and parens:
                    parens -= 1
            if char in "\n;" and not bracket and not parens:
                statement = "".join(buffer).strip()
                if statement:
                    first = next(i for i, item in enumerate(buffer) if not item.isspace())
                    yield locations[first], statement
                buffer, locations = [], []
                index += 1
                continue
        buffer.append(char)
        locations.append(program.lines[index])
        index += 1
    statement = "".join(buffer).strip()
    if statement:
        first = next(i for i, item in enumerate(buffer) if not item.isspace())
        yield locations[first], statement


def top_level(program):
    """Exclude control-flow conditions and bodies, not explicit assertions."""
    depth = 0
    for line, statement in statements(program):
        if re.match(r"^(?:(?:fi|done|esac)\b|\})", statement):
            depth = max(0, depth - 1)
            continue
        if re.match(r"^(?:if|while|until|for|select|case)\b", statement):
            if depth == 0:
                # The compound command has its own exit status. Retain it
                # even though its condition/body assertions are not scanned.
                yield line, "compound command"
            depth += 1
            continue
        if re.match(r"^[\w-]+\s*\(\)\s*\{", statement) or statement == "{":
            if depth == 0:
                yield line, "function or group"
            if not statement.endswith("}"):
                depth += 1
            continue
        if depth == 0 and not re.match(r"^(?:then|do|else|elif)\b", statement):
            yield line, statement


# Explicit exceptions: arithmetic assignment/increment is state mutation, not
# an assertion. Conditional lists already handle failure deliberately. Final
# statements return their status to BATS and therefore need no extra exit.
# No file/line exemptions: moving a test cannot silently grant an exception.
CHECK = re.compile(r"^(?:!\s|\[\[\s|\[\s|test\s|\(\(|(?:command\s+)?grep\s+-[A-Za-z]*q)")
ARITHMETIC_UPDATE = re.compile(r"\+\+|--|(?<![=!<>])=(?!=)")


def handles_status(statement):
    """Find real list operators, outside quoted data and test expressions."""
    quote = None
    bracket = 0
    parens = 0
    index = 0
    while index < len(statement):
        char = statement[index]
        pair = statement[index:index + 2]
        if char == "\\" and quote != "'":
            index += 2
            continue
        if quote is not None:
            if char == quote:
                quote = None
            index += 1
            continue
        if char in "'\"":
            quote = char
        elif pair == "[[":
            bracket += 1
            index += 2
            continue
        elif pair == "]]" and bracket:
            bracket -= 1
            index += 2
            continue
        elif not bracket:
            if char == "(":
                parens += 1
            elif char == ")" and parens:
                parens -= 1
            elif not parens and pair in ("||", "&&"):
                return True
        index += 1
    return False


def findings(text):
    lines = []
    line = 1
    for char in text:
        lines.append(line)
        line += char == "\n"
    seen = set()
    for program in programs(text, lines):
        commands = list(top_level(program))
        for line, statement in commands[:-1]:
            if not CHECK.match(statement):
                continue
            if statement.startswith("((") and ARITHMETIC_UPDATE.search(statement):
                continue
            if handles_status(statement):
                continue
            item = (line, " ".join(statement.split()))
            if item not in seen:
                seen.add(item)
                yield item


def main():
    violations = 0
    for argument in sys.argv[1:]:
        path = Path(argument)
        for line, statement in findings(path.read_text(encoding="utf-8")):
            print(f"{path}:{line}: unchecked non-final Zsh assertion: {statement}")
            violations += 1
    return int(bool(violations))


if __name__ == "__main__":
    sys.exit(main())
