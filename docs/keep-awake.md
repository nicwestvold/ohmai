# Keeping the Mac awake (advanced)

Off by default. Under **Settings → Advanced**, ohmai can prevent idle sleep while an agent is working, using a standard power assertion (the same mechanism as `caffeinate`). It's released as soon as agents stop or go quiet.

- **Every claim expires.** A session has to keep showing it's alive: its process is still running and is the same process, and it keeps writing. An agent waiting on you counts for at most an hour; a working agent that writes nothing for an hour is treated as stuck. Both limits are adjustable.
- **Sleep is always allowed** on battery below 50% (adjustable), in Low Power Mode, and when the Mac gets hot.
- If ohmai quits or crashes, macOS drops the assertion automatically.

## Lid closed (optional, off by default)

A MacBook sleeps when its lid closes, even mid-task. Turning on **Keep working with the lid closed** (Settings → Advanced) installs a small helper so a *working* agent can continue with the lid shut; an agent waiting on you never does. The helper runs as root, so macOS asks you to approve it in Login Items.

It's deliberately minimal and fails safe:

- Its only action is `pmset -a disablesleep 0|1`; it accepts no other commands.
- It only accepts requests from ohmai, checked by code signature (team and bundle ID).
- ohmai renews a 90-second lease every 30 seconds. If ohmai stops (crash, hang, quit), the helper turns sleep back on by itself within 90 seconds. It also turns sleep back on when it starts or stops, on battery below 30%, and when the Mac gets hot, checking these itself.
- Turning the option off removes the helper.

To check at any time: `pmset -g | grep -i sleepdisabled` shows 0 (or nothing) when sleep is allowed; `sudo pmset -a disablesleep 0` restores it by hand.

The design, including the dead-man switch, is in [design.md](design.md).
