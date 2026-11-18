# Parallel browser reads

Canonical browser reads can overlap across three clients in an unlocked Mac session. The app agent gives each reader its own configuration and serializes requests from the same client. Native and mixed work still uses exclusive admission, with priority once queued.

The browser helper checks authorization again before a scoped transport command. A Mac session change can stop a read without replaying it. Locked Use recovery and lease handling remain on the original exclusive path.

The test fixture requires two independent helpers to reach a barrier before either can finish its request. It exercises the Swift request gate and local JSON-RPC helper transport without starting Chrome.
