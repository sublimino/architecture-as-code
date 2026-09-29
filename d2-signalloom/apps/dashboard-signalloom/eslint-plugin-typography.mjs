import fs from 'node:fs';
import path from 'node:path';

function loadAllowlist(allowlistPath) {
  try {
    if (fs.existsSync(allowlistPath)) {
      return JSON.parse(fs.readFileSync(allowlistPath, 'utf8'));
    }
  } catch (e) {
    console.error('Error reading typography allowlist:', e);
  }
  return {};
}

const noEmDashRule = {
  meta: {
    type: 'problem',
    docs: {
      description: 'Disallow em-dash (—) characters in UI source strings, JSX text, and template literals.',
      category: 'Typography',
    },
    schema: [
      {
        type: 'object',
        properties: {
          allowlistPath: { type: 'string' },
        },
        additionalProperties: false,
      },
    ],
    messages: {
      noEmDash: "Disallowed em-dash ('—') character found. Replace with proper punctuation (: , () or sentence break; never en-dash).",
      countExceeded: "Em-dash count ({{count}}) exceeds allowlist limit ({{limit}}) for file {{file}}.",
    },
  },
  create(context) {
    const options = context.options[0] || {};
    const cwd = context.cwd || process.cwd();
    const allowlistPath = options.allowlistPath
      ? path.resolve(cwd, options.allowlistPath)
      : path.resolve(cwd, 'typography-allowlist.json');

    const allowlist = loadAllowlist(allowlistPath);
    const filename = context.filename || (context.getFilename && context.getFilename()) || '';

    let relPath = path.relative(cwd, filename).replace(/\\/g, '/');
    if (relPath.startsWith('d2-signalloom/apps/dashboard-signalloom/')) {
      relPath = relPath.slice('d2-signalloom/apps/dashboard-signalloom/'.length);
    }
    const srcIndex = relPath.indexOf('src/');
    const canonicalPath = srcIndex !== -1 ? relPath.slice(srcIndex) : relPath;

    if (canonicalPath.includes('.test.') || canonicalPath.includes('.spec.')) {
      return {};
    }

    const violations = [];

    function checkValue(node, value) {
      if (typeof value === 'string' && value.includes('\u2014')) {
        violations.push({ node, value });
      }
    }

    return {
      Literal(node) {
        if (typeof node.value === 'string') {
          checkValue(node, node.value);
        }
      },
      JSXText(node) {
        checkValue(node, node.value);
      },
      TemplateElement(node) {
        if (node.value && typeof node.value.raw === 'string') {
          checkValue(node, node.value.raw);
        }
      },
      'Program:exit'() {
        if (violations.length === 0) return;

        const allowedCount = allowlist[canonicalPath] ?? allowlist[relPath] ?? 0;

        if (violations.length > allowedCount) {
          if (allowedCount === 0) {
            for (const { node } of violations) {
              context.report({
                node,
                messageId: 'noEmDash',
              });
            }
          } else {
            for (let i = allowedCount; i < violations.length; i++) {
              context.report({
                node: violations[i].node,
                messageId: 'countExceeded',
                data: {
                  count: violations.length,
                  limit: allowedCount,
                  file: canonicalPath,
                },
              });
            }
          }
        }
      },
    };
  },
};

export default {
  rules: {
    'no-em-dash': noEmDashRule,
  },
};
