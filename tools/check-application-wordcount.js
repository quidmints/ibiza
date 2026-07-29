#!/usr/bin/env node
// Word count per section of FUNDING-APPLICATION.md, checked against the limit written in each
// heading AND against the count written beside it.
//
// THE COUNTS IN THE HEADINGS ARE CLAIMS, AND A CLAIM THAT NOBODY CHECKS GOES STALE ON THE FIRST
// EDIT. The funder's limits are hard - a section over the limit is a rejected application, and a
// heading that says "297 used" when the section holds 340 is worse than no number at all, because
// it stops anyone from looking. So this script is the thing that makes the numbers mean something:
// it recomputes them and fails if either the limit or the stated count is wrong.
//
//   node tools/check-application-wordcount.js          report and verify
//   node tools/check-application-wordcount.js --write  rewrite the stated counts in place
//
// COUNTING RULE. Markdown punctuation that carries no words is stripped before splitting on
// whitespace: emphasis markers, backticks, list bullets, blockquote markers, and the em-dash
// (which we use unspaced, so "power — a promise" would otherwise count the dash as a word).
// Section headings are NOT counted; the limit applies to the body a reader reads.

const fs = require("fs");
const path = require("path");

const DOC = path.join(__dirname, "..", "FUNDING-APPLICATION.md");
const WRITE = process.argv.includes("--write");

/** Strip markdown syntax that isn't a word, then split on whitespace. */
function countWords(body) {
  return body.replace(/[#*_`>\-—]/g, " ").split(/\s+/).filter(Boolean).length;
}

const text = fs.readFileSync(DOC, "utf8");
const lines = text.split("\n");

// A section is "## <n>. <title> *(<limit> max[ — <count> used])*" through to the next "## ".
const HEADING = /^## (.+?)\s*\*\((\d+) max(?:\s*—\s*(\d+) used)?\)\*\s*$/;

const sections = [];
lines.forEach((line, i) => {
  const m = HEADING.exec(line);
  if (m) sections.push({ line: i, title: m[1], limit: +m[2], stated: m[3] ? +m[3] : null });
});

if (sections.length === 0) {
  console.error(`${path.basename(DOC)}: no "## ... *(N max)*" headings found`);
  process.exit(1);
}

let failed = false;
sections.forEach((s, idx) => {
  const end = idx + 1 < sections.length ? sections[idx + 1].line : lines.length;
  s.actual = countWords(lines.slice(s.line + 1, end).join("\n"));

  const over = s.actual > s.limit;
  const misstated = s.stated !== null && s.stated !== s.actual;
  if (over || (misstated && !WRITE)) failed = true;

  const flag = over
    ? `OVER by ${s.actual - s.limit}`
    : misstated
      ? `heading says ${s.stated}`
      : "";
  console.log(
    `${String(s.actual).padStart(5)} / ${String(s.limit).padEnd(5)} ${flag.padEnd(18)} ${s.title}`,
  );
});

if (WRITE) {
  sections.forEach((s) => {
    lines[s.line] = `## ${s.title} *(${s.limit} max — ${s.actual} used)*`;
  });
  fs.writeFileSync(DOC, lines.join("\n"));
  console.log(`\nwrote ${sections.length} counts into ${path.basename(DOC)}`);
  // A section over its limit is still a failure after --write; the number is now honest, but the
  // section is still too long.
  process.exit(sections.some((s) => s.actual > s.limit) ? 1 : 0);
}

process.exit(failed ? 1 : 0);
