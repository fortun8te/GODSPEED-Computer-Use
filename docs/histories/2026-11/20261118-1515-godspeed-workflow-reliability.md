# Godspeed workflow reliability

Godspeed now gives clicks a short ripple at the target and respects Reduce Motion. Consecutive cursor movements coalesce within their action, and click feedback stays separate from input delivery.

Typing checks the live editor and active modal, avoids a screenshot for its initial AX lookup, and verifies readable accessibility writes. Browser clients and peek lanes use distinct identifiers. Peek reads an explicitly identified opened tab and uses a shared timeout budget.

Text-only JavaScript reads skip image capture by default. Tool telemetry records outcomes and timing by default, and reviewed fixture capture is opt-in. Shared app-agent connections use their own capture settings.
