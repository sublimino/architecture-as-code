import test from "node:test";
import assert from "node:assert/strict";
import { checkMarkdown } from "./ste-check.mjs";

test("accepts exact identifiers and commands inside code fences", () => {
  assert.deepEqual(checkMarkdown("---\ntitle: Generate the index\n---\n\nRun `generate; --very-long-command` now.\n\n```bash\nutilize the cache; prior to start\n```\n"), []);
});

test("rejects banned wording and prose semicolons", () => {
  const rules = checkMarkdown("Utilize the cache; start the server.").map(f => f.rule);
  assert.deepEqual(rules, ["8.1", "1.1"]);
});

test("uses a 20-word limit for instructions and warnings", () => {
  const sentence = Array(21).fill("word").join(" ") + ".";
  assert.equal(checkMarkdown(`1. ${sentence}`)[0].rule, "5.1");
  assert.equal(checkMarkdown(`WARNING: ${sentence}`)[0].rule, "5.1");
  assert.deepEqual(checkMarkdown(Array(20).fill("word").join(" ") + "."), []);
});

test("joins wrapped paragraphs and uses a 25-word description limit", () => {
  const words = Array(26).fill("word");
  assert.equal(checkMarkdown(words.slice(0, 13).join(" ") + "\n" + words.slice(13).join(" ") + ".")[0].rule, "6.3");
  assert.deepEqual(checkMarkdown(Array(25).fill("word").join(" ") + "."), []);
});

test("checks continued instructions but excludes fenced code and tables", () => {
  const source = "1. " + Array(12).fill("word").join(" ") + "\n   " + Array(10).fill("word").join(" ") + ".\n\n~~~text\nUtilize this;\n~~~\n\n| A | Utilize this; |\n";
  assert.deepEqual(checkMarkdown(source).map(f => f.rule), ["5.1"]);
});

test("counts inline code and link labels without link destinations", () => {
  assert.deepEqual(checkMarkdown("1. Run `make docs-dev-lint` and open [the guide](https://example.test/a/very/long/path)."), []);
});

test("ignores comment bodies without disabling subsequent checks", () => {
  const source = "<!-- Utilize this;\nprior to this -->\n\nUtilize the cache.";
  assert.deepEqual(checkMarkdown(source).map(f => f.rule), ["1.1"]);
});

test("checks HTML prose and text around inline comments", () => {
  assert.deepEqual(checkMarkdown("<p>Utilize the cache; prior to startup.</p>").map(f => f.rule), ["8.1", "1.1", "1.1"]);
  assert.deepEqual(checkMarkdown("Text <!-- note --> Utilize the cache;").map(f => f.rule), ["8.1", "1.1"]);
});
