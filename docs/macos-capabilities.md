# macOS capability audit

Godspeed is the Mac app and Chrome control layer. Use typed tools for observation and input, and batch related steps with an observable result. Use a supported app API or file tool when the task can be completed directly. System changes and account actions need their own explicit authority.

This audit describes the source and available routes. Individual app behavior needs verification.

| Category | Godspeed coverage and route |
| --- | --- |
| 1. Mouse | Left, right and middle click with a click count, element or screenshot coordinates, directional scrolling, targeted drag with optional modifiers, and native hover on an observed element. Persistent button holds, pointer acceleration and extra buttons are outside the current API. |
| 2. Trackpad and gestures | Use app controls, keyboard shortcuts or scroll and drag for equivalent app results. Raw multi-touch, pressure and system gestures are unimplemented. |
| 3. Keyboard | Type text with Unicode and send a key or shortcut through the app-scoped route. Physical held-key streams, keyboard layout changes and media-specific keys are outside the generic contract. |
| 4. Text editing | Use type, set value, select text, and supported app menu commands or shortcuts for editing and formatting. Verify selection and persistence in the target app. Dictation belongs to the voice layer. |
| 5. Clipboard | App menu shortcuts can copy and paste when explicitly authorized. Standalone global clipboard reads, format conversions and clipboard clearing are outside the Godspeed API. |
| 6. Accessibility | Read and query AX trees, resolve controls by label or index, set values, select text and perform supported secondary actions. A given element's supported actions come from the app. |
| 7. UI controls | Compose click, value setting, menus, keys and secondary actions. Use snapshots to discover actual controls in custom apps and dialogs. |
| 8. Windows | Observe the current app window and use supported window placement or app actions. Exact-window addressing across all native tools and general window management are gaps. |
| 9. Applications | List, open and target apps, files or supported URLs. App menus handle supported commands. Force quit, daemon management and process supervision belong to separate tools. |
| 10. Desktop and navigation | Use an accessible target app or a supported command for the task. Global desktop transitions, hot corners and Trackpad-driven system navigation are outside the default background route. |
| 11. Screen and vision | Capture the observed window when requested, compare app state and optionally use a local visual fallback. Region masking, multi-display capture and recording are separate capabilities. |
| 12. Finder and files | Use Finder and supported file dialogs for UI workflows. Use direct file tools for ordinary file operations. Verify complex selections, moves and bulk import independently. |
| 13. Browser | Scoped Chrome sessions support navigation, tabs and selection, reads, screenshots, click, hover, drag, type, keys, form controls, waits and upload. Browser data management and developer APIs are separate authorized capabilities. |
| 14. Terminal and shell | Use the caller's authorized shell or developer tools. Godspeed's optional JavaScript adapter provides a UI-oriented programmable surface. |
| 15. System Settings | Open supported panes and use accessible controls. Settings changes require explicit task authority. Hardware and OS-specific settings belong to supported system interfaces. |
| 16. Power and sessions | Use the dedicated system route for a scoped request. Suspend, lock, log out, reboot and shutdown are outside routine Godspeed workflow execution. |
| 17. Audio and media | Use accessible app playback controls or the dedicated media or audio tool. Capture and device changes use permission-aware system interfaces. |
| 18. Camera and peripherals | Use the vendor app or supported hardware APIs. Capture and device access remain user-authorized. |
| 19. Notifications and dialogs | Observe and act on accessible ordinary alerts, sheets, save and file dialogs. Authentication and system permission prompts remain user-controlled. |
| 20. Networking | Use the caller's authorized network or diagnostics tool. The UI driver can open approved browser destinations. |
| 21. Automation frameworks | Godspeed uses accessibility and targeted events internally. App scripting, Shortcuts and other automation belong to the authorized host tools. |
| 22. Low-level input | Generate the scoped key and mouse events needed by the tools. Raw event taps, global keyboard observation, virtual HID, and arbitrary event streams are outside the public API. |
| 23. Processes and services | List and open target apps through Godspeed. Process and service administration uses its own authorized route. |
| 24. Displays and monitors | Window capture and coordinates are window-scoped. A display-management tool is the right route for arrangement, mirroring, brightness or refresh settings. |
| 25. Documents and productivity | Use app controls or direct document interfaces. Verify the saved artifact or final document state and app-specific behavior. |
| 26. Communication | Use an authorized app or connector, with explicit scope for sending, posting or sharing. Drafting and verification can be separate steps. |
| 27. Developer tools | Use Godspeed for the UI portions of editor, simulator or web workflows. Use Git, shell and build interfaces for the rest. |
| 28. Data and databases | Use structured APIs or file tools for extraction and edits. Use UI mode when the task specifically requires the workflow through an app. |
| 29. Printing and sharing | Use accessible app menu commands and authorized destinations. Check permission and final state for real print or share delivery. |
| 30. Security and permissions | Inspect readiness and use guided onboarding. System approvals and credentials stay with the user and supported secure interfaces. |
| 31. System monitoring | Use read-only OS metrics or the user's monitoring app for resource data. Godspeed records its own tool outcomes and timing. |
| 32. Event observation | Use fresh AX state, bounded waits and browser readiness checks. Continuous system input, clipboard, filesystem or network monitoring is outside normal Godspeed operation. |
| 33. Remote control | Use the user's authorized remote environment tooling. The native driver runs on the target Mac. |
| 34. Advanced UI automation | Semantic lookup, coordinate fallback, optional visual grounding, bounded waits, postcondition checks and partial-failure receipts. Recover from fresh state. |
| 35. Workflow orchestration | Ordered batches and postconditions, optional recipe replay, and bounded concurrent browser reads. Scheduling and multi-agent orchestration belong to the host. |
| 36. App-specific actions | Compose available controls through the UI or use a supported app interface. Validate representative workflows independently for each app. |
| 37. Special hardware and restricted actions | User completes authentication and permission prompts. Device-specific hardware and privileged operations require their supported interfaces. |

## Priority

First validate native hover, exact-window targeting, dialogs and drag in disposable real-app fixtures. Score the requested outcome and whether the foreground user's work was disturbed. Then address the repeated missing actions that those fixtures reveal.
