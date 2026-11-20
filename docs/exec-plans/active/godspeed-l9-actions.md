# Godspeed action gaps

Source inventory at `cc7fddb`, the 1.1.11 release base.

| Capability | Native at the release base | Chrome at the release base | Work in this lane |
| --- | --- | --- | --- |
| Scroll | AX whole pages or a wheel estimate. No progress check. | Pixel or viewport scroll, nested boxes and scroll into view. No position delta. | Add explicit units and bounded progress checks. Keep legacy arguments. |
| Precise click | AX press or a screenshot point. AX menu action where exposed. | Hit-tested control, modifiers, right and middle button, left double-click. | Add control-relative targeting and test click counts. Use selected rows or Shift with a verified route. |
| Drag | Window-bound points with fixed steps and optional modifiers. | Two visible controls with fixed steps and optional modifiers. | Add native element endpoints and configurable timing. Verify the drop with an observable batch condition. |
| File drag | Pointer delivery alone cannot confirm a Finder drop. Private clipboard already handles Finder file moves. | Labelled file upload already verifies selected files. | Document those routes. Report the limits of generic pointer delivery. |
| Gestures | AX actions and app menus can express some outcomes. No raw trackpad gestures. | Tab-scoped history already supports back and forward. | Offer reliable equivalents and a typed error when no route exists. |
| Hover | Window-bound mouse move with a short read-back pause. | Tab-scoped mouse move. | Add bounded dwell. |
| Text selection | AX selection by text and context, with range read-back. | Clipboard uses Chrome selection internally. No explicit selection action. | Add UTF-16 range selection and Chrome field selection. |
| Keys | Single key or chord, sometimes through the app's menu equivalent. | CDP key down and up for a single key or chord. | Add a bounded hold where release can be guaranteed. |
| Wait | Batch can wait for text, absence, window or settle. | Wait for URL, text, a label or a control state. | Add a bounded value-change check and exact presence or absence where observable. |

The release's benchmark describes live workflows. This lane uses only headless tests.
