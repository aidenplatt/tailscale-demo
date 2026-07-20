# Private Web Service Access via Tailscale (Tags + ACLs)

### Overview

This project stands up a small tailnet with two nodes:

- **`web`** – an nginx container serving a private web page, run via Docker.
  It publishes **no ports to the host or the public internet** —
  the only network path to it is through Tailscale.
- **My laptop** – a real physical device on the same tailnet, tagged
  `tag:client`, used to prove that access works as intended. This is not a
  container — it's the machine I'm actually working on, connected via the
  native Tailscale app.

Access between them is controlled entirely by a Tailscale ACL policy based
on **tags**: `tag:client` devices may reach `tag:server` devices on port 80,
and nothing else is permitted by default.

### Why this use case

I picked this over a more elaborate architecture on purpose. The assignment
explicitly says a simple, well explained solution beats a complex one, and
"private service + ACLs & tags" is the single most common real-world reason a
customer adopts Tailscale: they have an internal tool (an admin dashboard,
an API, a database UI) that they don't want to expose to the public internet,
don't want to manage a VPN concentrator or bastion host for, and want tightly
scoped so only the right group of people/services can reach it — not "anyone
on the corporate VPN."

I deliberately used my own laptop as the client node rather than a second
container. A real physical device reaching a private containerized service
is closer to the actual customer scenario Tailscale solves, and it let me
validate the whole flow (auth, tagging, ACL enforcement, MagicDNS) the same
way an actual end user would experience it.

Tags (rather than per user ACLs) were chosen specifically because they scale
the way a real deployment would: adding a second client machine, or a
teammate's laptop, later only requires tagging it correctly, not editing
the ACL policy itself.

### Architecture

```
                     +--------------------------+
                     |        Tailnet           |
                     |  (WireGuard mesh, all    |
                     |  traffic encrypted e2e)  |
                     +--------------------------+
                        |                  |
              tag:client|                  |tag:server
                        |                  |
              +---------v------+  +--------v---------+
              |   My laptop     |  |   web (nginx)     |
              |                 |  |   container        |
              |  native         |  |                    |
              |  Tailscale app  |  |  tailscaled sidecar |
              |                 |  |  (Docker Compose)   |
              |                 |  |  network_mode:      |
              |                 |  |  service:web)       |
              +-----------------+  +--------------------+
  ACL policy (policy.hujson) using the current "grants" syntax:
    tag:client -> tag:server, port 80   [ALLOW]
    everything else                    [DENY - default]

  The web container has no "ports:" mapping to the Docker host.
  The only route to it is: my laptop -> tailnet -> web, port 80.
```

**Traffic flow:** my laptop resolves `web` via MagicDNS
(`web.tail3815aa.ts.net`), opens a WireGuard connection to it over the
tailnet, Tailscale's control plane checks the grant (`tag:client` -> `tag:server:80`, allowed),
the Tailscale sidecar forwards the request to nginx over the shared network
namespace, and nginx serves the page back over the same encrypted tunnel.

### Setup and deployment

#### Prerequisites
- Docker Desktop (Apple Silicon build — my MacBook runs an A18 Pro chip)
- A free Tailscale account, with the native app installed and connected on
  my laptop
- One auth key, tagged `tag:server`, generated from the admin console

#### Steps

```bash
git clone https://github.com/aidenplatt/tailscale-demo.git
cd tailscale-demo

# Apply policy.hujson at https://login.tailscale.com/admin/acls
# Tag your laptop tag:client at https://login.tailscale.com/admin/machines

cp .env.example .env
# edit .env, add your TS_AUTHKEY_SERVER value

docker compose up -d
tailscale status          # confirm "web" shows up and is online

chmod +x scripts/validate.sh
./scripts/validate.sh
```

### How to validate that it works

`scripts/validate.sh` runs directly on my laptop (not via `docker exec`,
since my laptop is the client node, not a container) and:
1. Prints `tailscale status`, showing both my laptop and `web` online.
2. Resolves `web`'s tailnet IP via MagicDNS.
3. Curls the web service over the tailnet and captures the real HTML
   response — including a custom page I wrote to make the success state
   obvious at a glance.

I also validated this manually in a browser by visiting
`http://web.tail3815aa.ts.net` directly and confirming the custom page
rendered.

### Assumptions / prerequisites

- Assumes a personal Tailscale account with admin access to the ACL policy
  editor and the ability to tag devices.
- Assumes Docker Desktop has access to `/dev/net/tun` for the sidecar
  container.
- The auth key is treated as a secret, kept in `.env`, and is not committed
  (see `.gitignore`).

### What worked well

- The sidecar pattern (a Tailscale container sharing the nginx container's
  network via `network_mode: service:web`) meant I could use the official,
  unmodified `nginx:alpine` and `tailscale/tailscale` images together
  without building any custom image.
- Tag-based ACLs made the access rule a single, readable statement instead
  of a list of exceptions, and it was genuinely satisfying to prove the
  rule mattered by temporarily removing it and watching access fail.
- MagicDNS meant I never had to hardcode or track an IP address by hand.

### What was difficult or surprising

- **`hostname` vs. `network_mode` conflict.** My first `docker compose up`
  failed with `conflicting options: hostname and the network mode`. The
  `web-tailscale` sidecar had both an explicit `hostname: web` setting and
  `network_mode: service:web` (which shares the entire network namespace,
  hostname included, with the `web` container). Once I understood that
  hostname is part of a network namespace, not a separate independent
  setting, the fix was obvious: remove the redundant explicit hostname and
  let it inherit from the shared namespace instead.
- **Tailscale on my Mac stuck on "VPN starting."** This turned out to be
  resolved by a pending macOS software update.
- **Docker container reporting "Network unreachable."** After getting both
  containers running, the sidecar started flapping between healthy and
  "could not connect to the Los Angeles relay server." Testing from inside
  the container with `curl` (more reliable than `ping` in Docker's Mac VM)
  confirmed it had no outbound internet access at all. A full
  `docker compose down` followed by fully quitting and reopening Docker
  Desktop (not just restarting the containers) resolved it.
- **Understanding tags vs. topology.** It took me a bit to internalize that
  being on the same tailnet doesn't mean two devices can reach each other —
  the mesh network defines what's *possible*, and the ACL policy separately
  defines what's *permitted*. Those are two different layers, and
  conflating them was my biggest early misunderstanding.

### What I'd do differently with more time

- With more time, I'd want to explore other Tailscale use cases beyond a 
  single private service — like exposing a whole private network through a 
  subnet router, or comparing tailnet-only access against deliberately making
  something public with Funnel — mainly to build a clearer mental model of
  when you'd reach for each approach with a real customer. 

### Where AI assistance was used

I used Claude throughout this project as a study partner while I was
learning Tailscale concepts (tailnets, MagicDNS, ACL syntax etc..). 
Claude also assisted me with coding the project and debugging the errors as they
came up — including the hostname/network_mode conflict, the stuck Tailscale
connection on my laptop and the Docker Desktop networking issue. 