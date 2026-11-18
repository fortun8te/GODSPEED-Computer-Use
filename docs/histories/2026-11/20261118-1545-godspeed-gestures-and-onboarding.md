# Permissions, gestures and receipts

The setup panel uses the packaged red glass icon as a draggable app tile. It opens the relevant System Settings page and keeps the controls stable between permission checks.

The cursor now shows active and completed input, including drag, drop, typing, directional scroll, and secondary clicks. Interrupted input clears the active indicator. Targeted drags carry movement deltas and one gesture identity during down, move, and release. Chrome can deliver a pointer drag between visible controls in a selected tab.

Sibling MCP clients get separate browser configurations and identities by default. Explicitly named clients can share a session. The shared app agent retains its serialized dispatch and existing Locked Use checks.

Local receipt schema v3 captures fixed failure codes, each batch step's outcome, and verification status. UI content remains opt-in.
