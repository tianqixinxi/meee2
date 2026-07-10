# Meee2 web chat bridge (retired)

The sideloaded Chrome/Edge bridge is retired. BoardServer no longer accepts
external-session mutations, and launch-scoped control credentials are not
exposed to browser extensions.

Version 0.1.1 removes content-script registration and all host permissions.
Its popup remains only to explain the retirement to existing sideloaded users;
it performs no localhost discovery, network requests, or payload queuing.

Meee2 now displays only sessions it creates through supported agent
integrations.
