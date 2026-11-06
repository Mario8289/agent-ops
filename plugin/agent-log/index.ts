// agent-log — append notable agent events to the log watched by the
// "Agent Ops" Zellij layout (pane command: agent-log).
// Part of the agent-ops project: https://github.com/Mario8289/agent-ops
//
// Logged events:
//   permission.asked             -> agent is WAITING for your approval
//   permission.replied           -> agent RESUMED after your reply
//   session.execution.succeeded  -> agent finished, waiting for your input
//   session.execution.interrupted-> agent run was interrupted
//   session.execution.failed     -> agent run failed
//
// Each line starts with [session12 project] so it can be matched to the
// Agent Inbox pane (agent-inbox), which shows the full ID and project. 12 chars
// rather than 8 because the leading chars are time-derived and two sessions
// started in the same minute share their first 8.
//
// Note: session.idle is deprecated and session.status is ephemeral (not
// delivered to plugins), so the durable execution events are used instead.
//
// Path override order: plugin option "log" > $AGENT_LOG > ~/agent-runs/agent_health.log
//
// Notifications (same events, so you don't have to watch the pane):
//   ASK / FAIL   desktop popup + phone push
//   IDLE         desktop popup + phone push (suppressed while you look at it)
//   STOP         desktop popup only
// Nothing is sent when the session's own pane is the focused Zellij pane, and a
// session is notified at most once per 30s per kind. ASK / IDLE / FAIL are
// repeated to the phone every 30 minutes (4 times at most) until the session
// shows activity again.
//
// Phone push goes through ntfy and is opt-in per machine: it is sent only if
// ~/.config/agent-ops/ntfy-topic exists. Put a long random topic in it
// (`openssl rand -hex 16`), or a full URL for a self-hosted server, and keep
// the file out of the repo (chmod 600). Create it on personal machines only.
// A file rather than an env var because this plugin runs inside the background
// `opencode serve` service, which does not see variables exported in your shell.
// The public ntfy.sh topic name is the only secret, so the phone message carries
// only "project: status" plus a safe category (the tool name for ASK, the error
// type for FAIL) — never commands, paths, titles or error text. The desktop
// popup is local, so it does include the request or error text.
//
// Planned, not built: deciding from the phone. Run Tailscale, bind `opencode
// serve` to the tailnet only (it has no visible auth option, and a session can
// run shell commands, so never expose it publicly), and make the notification
// link to the session in the web UI. The detail would then travel over the
// private network instead of through ntfy. Verify the web UI supports
// permission approvals and chat first.
import { Plugin } from "@opencode/plugin"
import { execFile } from "node:child_process"
import { appendFileSync, mkdirSync, readFileSync } from "node:fs"
import { homedir } from "node:os"
import { basename, dirname, join } from "node:path"
import { promisify } from "node:util"

const run = promisify(execFile)
const THROTTLE_MS = 30_000
const REMIND_MS = 30 * 60_000
const MAX_REMINDERS = 4

const pad = (n: number) => String(n).padStart(2, "0")

function stamp() {
  const d = new Date()
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
}

export default Plugin.define({
  id: "agent-log",
  setup(ctx) {
    const option = typeof ctx.options.log === "string" ? ctx.options.log : undefined
    const file = option ?? process.env.AGENT_LOG ?? join(homedir(), "agent-runs", "agent_health.log")
    mkdirSync(dirname(file), { recursive: true })

    // Same prefix as the Agent Inbox pane: first 12 chars of the session ID
    // plus the project name, so a line here can be matched to a row there.
    const project = (basename(ctx.location.directory) || "?").slice(0, 12)
    const tag = (id: string) => `${id.slice(0, 12)} ${project}`

    // Some events (e.g. session.execution.failed) have no event.location, so every
    // project's plugin instance would log the same line. Ask the server which
    // directory the session belongs to and let only that instance write it.
    const owns = async (sessionID: string) => {
      try {
        const session = (await ctx.session.get({ sessionID })) as {
          directory?: string
          location?: { directory?: string }
        }
        const dir = session.directory ?? session.location?.directory
        return !dir || dir === ctx.location.directory
      } catch {
        return true
      }
    }

    // Keep every line one line and short enough for the Zellij pane.
    const clip = (s: string, max = 120) => {
      const one = s.replace(/\s+/g, " ").trim()
      return one.length > max ? `${one.slice(0, max - 3)}...` : one
    }

    // A provider error is an object; show its type/message, not the whole JSON.
    const describe = (err: unknown) => {
      if (typeof err === "string") return err
      if (err && typeof err === "object") {
        const e = err as Record<string, unknown>
        const type = typeof e.type === "string" ? e.type : "error"
        const message = typeof e.message === "string" ? e.message : ""
        return message ? `${type}: ${message}` : type
      }
      return String(err)
    }

    const write = (line: string) => {
      try {
        appendFileSync(file, `[${stamp()}] ${line}\n`)
      } catch {
        // logging must never break the agent
      }
    }

    // Phone push target, or undefined when this machine has no topic file.
    const phoneTarget = () => {
      try {
        const t = readFileSync(join(homedir(), ".config", "agent-ops", "ntfy-topic"), "utf8").trim()
        if (!t) return undefined
        return /^https?:\/\//.test(t) ? t : `https://ntfy.sh/${t}`
      } catch {
        return undefined
      }
    }

    // Is this session's pane the focused one in any Zellij session? The service
    // is not inside Zellij, so ask each session by name.
    const watching = async (sessionID: string) => {
      try {
        const { stdout } = await run("zellij", ["list-sessions", "--short", "--no-formatting"], { timeout: 3000 })
        for (const name of stdout.split("\n").filter(Boolean)) {
          const out = await run("zellij", ["--session", name, "action", "list-panes", "--json"], { timeout: 3000 })
          const panes = JSON.parse(out.stdout) as Array<{ is_focused?: boolean; is_plugin?: boolean; title?: string }>
          if (panes.some((p) => p.is_focused && !p.is_plugin && p.title?.includes(sessionID))) return true
        }
      } catch {
        // no Zellij, or it is not answering: treat as not watching
      }
      return false
    }

    // Keep only safe characters for the phone message.
    const safe = (s: unknown, fallback: string) => {
      const t = typeof s === "string" ? s.replace(/[^\w.:-]/g, "").slice(0, 24) : ""
      return t || fallback
    }
    const errorKind = (err: unknown) =>
      safe(err && typeof err === "object" ? (err as Record<string, unknown>).type : undefined, "error")

    const push = (title: string, body: string, urgent: boolean) => {
      const target = phoneTarget()
      if (!target) return
      fetch(target, {
        method: "POST",
        body,
        headers: { Title: title, Priority: urgent ? "high" : "default" },
      }).catch(() => {})
    }

    const lastSent = new Map<string, number>()
    const reminders = new Map<string, ReturnType<typeof setInterval>>()

    const stopReminder = (sessionID: string) => {
      const t = reminders.get(sessionID)
      if (t) clearInterval(t)
      reminders.delete(sessionID)
    }

    const remind = (sessionID: string, phoneText: string) => {
      stopReminder(sessionID)
      if (!phoneTarget()) return
      let count = 0
      const t = setInterval(async () => {
        count += 1
        if (count >= MAX_REMINDERS) stopReminder(sessionID)
        if (!(await watching(sessionID))) push("Agent Ops", `${project}: still ${phoneText}`, false)
      }, REMIND_MS)
      t.unref?.()
      reminders.set(sessionID, t)
    }

    // desktop: local popup text. phone: the minimal message, or null for desktop only.
    const notify = async (kind: "ASK" | "IDLE" | "FAIL" | "STOP", sessionID: string, desktop: string, phone: string | null) => {
      try {
        const key = `${sessionID}:${kind}`
        const now = Date.now()
        if (now - (lastSent.get(key) ?? 0) < THROTTLE_MS) return write(`[${tag(sessionID)}] NOTIFY ${kind} skipped: throttled`)
        lastSent.set(key, now)
        if (await watching(sessionID)) return write(`[${tag(sessionID)}] NOTIFY ${kind} skipped: pane is focused`)
        execFile("notify-send", ["-a", "Agent Ops", `${project}: ${kind}`, clip(desktop, 160)], (err) => {
          write(`[${tag(sessionID)}] NOTIFY ${kind} desktop ${err ? `failed: ${clip(String(err), 80)}` : "sent"}`)
        })
        if (phone !== null) {
          push("Agent Ops", `${project}: ${phone}`, kind === "ASK" || kind === "FAIL")
          remind(sessionID, phone)
        }
      } catch (err) {
        write(`[${tag(sessionID)}] NOTIFY ${kind} error: ${clip(String(err), 80)}`)
      }
    }

    write(`LOADED ${project}`)

    const controller = new AbortController()
    void (async () => {
      for await (const event of ctx.event.subscribe({
        // Durable execution events: these are what the client uses to derive
        // busy/idle, and unlike session.status they are delivered to plugins.
        types: [
          "permission.asked",
          "permission.replied",
          "session.execution.started",
          "session.execution.succeeded",
          "session.execution.failed",
          "session.execution.interrupted",
        ],
        signal: controller.signal,
      })) {
        // The plugin runs once per project location on the shared server, and every
        // instance sees server-wide events. Log only our own location's events so a
        // single "waiting" event doesn't appear N times in the log.
        if (event.location) {
          if (event.location.directory !== ctx.location.directory) continue
        } else if (!(await owns(event.data.sessionID))) {
          continue
        }
        const sid = event.data.sessionID
        switch (event.type) {
          case "session.execution.started":
            stopReminder(sid)
            break
          case "permission.asked": {
            const detail = clip(`${event.data.action} ${(event.data.resources ?? []).join(" ")}`, 90)
            write(`[${tag(sid)}] WAITING ${detail}`)
            void notify("ASK", sid, detail, `needs approval (${safe(event.data.action, "request")})`)
            break
          }
          case "permission.replied":
            write(`[${tag(sid)}] RESUMED ${event.data.reply}`)
            stopReminder(sid)
            break
          case "session.execution.succeeded": {
            write(`[${tag(sid)}] IDLE waiting for your input`)
            void notify("IDLE", sid, "waiting for your input", "your turn")
            break
          }
          case "session.execution.interrupted":
            write(`[${tag(sid)}] INTERRUPTED`)
            stopReminder(sid)
            void notify("STOP", sid, "run was interrupted", null)
            break
          case "session.execution.failed": {
            const detail = clip(describe(event.data.error), 140)
            write(`[${tag(sid)}] FAILED ${detail}`)
            void notify("FAIL", sid, detail, `run failed (${errorKind(event.data.error)})`)
            break
          }
        }
      }
    })().catch(() => {})

    return () => {
      controller.abort()
      for (const id of [...reminders.keys()]) stopReminder(id)
    }
  },
})
