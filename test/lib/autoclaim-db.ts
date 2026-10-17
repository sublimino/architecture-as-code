import { SQL } from "bun";

const action = process.argv[2];
const pgPort = process.argv[3];
const target = process.argv[4];

if (!action || !pgPort) {
  console.error("Usage: bun test/lib/autoclaim-db.ts <action> <pgPort> [target]");
  process.exit(1);
}

// The superuser password is minted per cluster (scripts/postgres-superuser-secret.sh);
// read it from the Secret rather than assuming a constant.
function pgPassword(): string {
  if (process.env.SIGNALLOOM_PG_PASSWORD) return process.env.SIGNALLOOM_PG_PASSWORD;
  const out = Bun.spawnSync(["kubectl", "-n", "inf-signalloom", "get", "secret", "postgresql-superuser", "-o", "jsonpath={.data.password}"]);
  if (out.exitCode !== 0) throw new Error("cannot read inf-signalloom/postgresql-superuser; set SIGNALLOOM_PG_PASSWORD");
  return Buffer.from(out.stdout.toString().trim(), "base64").toString();
}

const sql = new SQL(`postgres://signalloom:${encodeURIComponent(pgPassword())}@localhost:${pgPort}/signalloom`);

try {
  if (action === "cleanup") {
    // Disable audit trigger temporarily, delete rows, re-enable trigger
    try {
      await sql`ALTER TABLE public.audit_events DISABLE TRIGGER audit_events_append_only`;
    } catch (_) {}

    await sql`DELETE FROM agent_compliance_results WHERE agent_id IN (SELECT id FROM agent_registry WHERE name = ${target})`;
    await sql`DELETE FROM agent_origin_verifications WHERE agent_id IN (SELECT id FROM agent_registry WHERE name = ${target})`;
    await sql`DELETE FROM audit_events WHERE agent_name = ${target}`;
    await sql`DELETE FROM agent_registry WHERE name = ${target}`;

    try {
      await sql`ALTER TABLE public.audit_events ENABLE TRIGGER audit_events_append_only`;
    } catch (_) {}
    console.log("ok");
  } else if (action === "get-agent") {
    const r = await sql`SELECT id, name, status, lifecycle_state FROM agent_registry WHERE name = ${target}`;
    if (r.length === 0) {
      console.error(`Agent ${target} not found in agent_registry`);
      process.exit(1);
    }
    console.log(JSON.stringify(r[0]));
  } else if (action === "get-origin") {
    const r = await sql`
      SELECT origin_type, auth_method, subject, verified, status 
      FROM agent_origin_verifications 
      WHERE agent_id = (SELECT id FROM agent_registry WHERE name = ${target})
    `;
    if (r.length === 0) {
      console.error(`Origin verification not found for ${target}`);
      process.exit(1);
    }
    console.log(JSON.stringify(r[0]));
  } else if (action === "get-compliance") {
    const r = await sql`
      SELECT control_id, status 
      FROM agent_compliance_results 
      WHERE agent_id = (SELECT id FROM agent_registry WHERE name = ${target})
    `;
    console.log(JSON.stringify({ count: r.length, results: r }));
  } else if (action === "get-audit") {
    const r = await sql`
      SELECT event_type, actor, detail 
      FROM audit_events 
      WHERE agent_name = ${target}
      ORDER BY timestamp DESC LIMIT 1
    `;
    if (r.length === 0) {
      console.error(`Audit event not found for ${target}`);
      process.exit(1);
    }
    console.log(JSON.stringify(r[0]));
  } else if (action === "count-agent") {
    const r = await sql`SELECT count(*) FROM agent_registry WHERE name = ${target}`;
    console.log(r[0].count);
  } else {
    console.error(`Unknown action: ${action}`);
    process.exit(1);
  }
} finally {
  await sql.close();
}
