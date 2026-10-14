import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Automated subset of STE-Code 1.1, 5.1, 6.3, and 8.1.
// Technical meaning, approved terminology, and command safety require review.
const banned = /\b(?:utili[sz]e|leverag(?:e|es|ed|ing)|in order to|prior to|facilitate|commence|whilst|simply|obviously|basically|click here)\b/gi;

function prose(text) {
  return text
    .replace(/`+[^`]+`+/g, "CODE")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "IMAGE")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/https?:\/\/\S+/g, "URL")
    .replace(/<[^>]*>/g, "")
    .replace(/[*_]/g, "");
}

function checkParagraph(paragraph, line, limit) {
  const findings = [];
  const text = prose(paragraph.join(" "));
  if (text.includes(";")) findings.push({ line, rule: "8.1", message: "Use two sentences instead of a semicolon." });
  for (const match of text.matchAll(banned)) {
    findings.push({ line, rule: "1.1", message: `Use a simple alternative to '${match[0]}'.` });
  }
  for (const sentence of text.split(/[.!?](?:\s|$)/)) {
    const words = sentence.trim().split(/\s+/).filter(Boolean).length;
    if (words > limit) findings.push({ line, rule: limit === 20 ? "5.1" : "6.3", message: `${words} words exceed the ${limit}-word limit.` });
  }
  return findings;
}

function skipRegion(line, index, state) {
  if (index === 0 && line === "---") { state.frontmatter = true; return true; }
  if (state.frontmatter) { state.frontmatter = line !== "---"; return true; }
  const marker = line.match(/^(`{3,}|~{3,})/);
  if (state.fence) {
    if (marker?.[1][0] === state.fence[0] && marker[1].length >= state.fence.length) state.fence = null;
    return true;
  }
  if (marker) { state.fence = marker[1]; return true; }
  return false;
}

export function checkMarkdown(source) {
  const findings = [];
  const state = { frontmatter: false, fence: null };
  let paragraph = [];
  let start = 0;
  let limit = 25;
  const flush = () => {
    findings.push(...checkParagraph(paragraph, start, limit));
    paragraph = [];
    limit = 25;
  };
  const withoutComments = source.replace(/<!--[\s\S]*?-->/g, comment => comment.replace(/[^\n]/g, " "));
  for (const [index, raw] of withoutComments.split(/\r?\n/).entries()) {
    const line = raw.trim();
    if (skipRegion(line, index, state)) { flush(); continue; }
    if (!line || /^(#|\||:::)/.test(line)) { flush(); continue; }
    const instruction = /^\d+\.\s+/.test(line) || /^(WARNING|CAUTION):/.test(line);
    const item = /^(?:\d+\.|[-+*])\s+/.test(line);
    if (item || instruction) flush();
    if (!paragraph.length) { start = index + 1; limit = instruction ? 20 : 25; }
    paragraph.push(line.replace(/^(?:\d+\.|[-+*])\s+/, ""));
  }
  flush();
  return findings;
}

function markdownFiles(root) {
  return fs.readdirSync(root, { withFileTypes: true }).flatMap(entry => {
    const file = path.join(root, entry.name);
    if (entry.isDirectory()) return markdownFiles(file);
    return /\.mdx?$/.test(entry.name) ? [file] : [];
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const root = path.resolve(process.argv[2] ?? "dev-docs/src/content/docs");
  const files = markdownFiles(root);
  if (!files.length) throw new Error(`No documentation files found in ${root}`);
  let count = 0;
  for (const file of files) {
    for (const finding of checkMarkdown(fs.readFileSync(file, "utf8"))) {
      console.error(`${file}:${finding.line}: STE ${finding.rule}: ${finding.message}`);
      count++;
    }
  }
  console.log(`STE-Code subset: ${files.length} files, ${count} findings. Editorial review remains required.`);
  process.exitCode = count ? 1 : 0;
}
