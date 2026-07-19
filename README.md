# Private Web Service Access via Tailscale (Tags + ACLs)

## Overview

This project stands up a small tailnet with two nodes:

- **`web`** – an nginx container serving a private web page, run via Docker
  Compose. It publishes **no ports to the host or the public internet** —
  the only network path to it is through Tailscale.
- **My laptop** – a real physical device on the same tailnet, tagged
  `tag:client`, used to prove that access works as intended. This is not a
  container — it's the machine I'm actually working on, connected via the
  native Tailscale app.

Access between them is controlled entirely by a Tailscale ACL policy based
on **tags**: `tag:client` devices may reach `tag:server` devices on port 80,
and nothing else is permitted by default (Tailscale ACLs are default-deny).

## Why this use case

I picked this over a more elaborate architecture on purpose. The assignment
explicitly says a simple, well-explained solution beats a complex one, and
"private service + ACLs/tags" is the single most common real-world reason a
customer adopts Tailscale: they have an internal tool (an admin dashboard,
an API, a database UI) that they don't want to expose to the public internet,
don't want to manage a VPN concentrator or bastion host for, and want tightly
scoped so only the right group of people/services can reach it — not "anyone
on the corporate VPN."

I deliberately used my own laptop as the client node rather than a second
container. Two containers on one machine can make for a slightly
artificial demo; a real physical device reaching a private containerized
service is closer to the actual customer scenario Tailscale solves — e.g.
"my laptop reaches an internal company tool" — and it let me validate the
whole flow (auth, tagging, ACL enforcement, MagicDNS) the same way an
actual end user would experience it, not just from inside Docker's network.

Tags (rather than per-user ACLs) were chosen specifically because they scale
the way a real deployment would: adding a second client machine, or a
teammate's laptop, later only requires tagging it correctly, not editing
the ACL policy itself.

## Architecture

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
              +-----------------+  +--------------------+

  ACL policy (policy.hujson):
    tag:client -> tag:server, tcp/80   [ALLOW]
    everything else                    [DENY - default]

  The web container has no "ports:" mapping to the Docker host.
  The only route to it is: my laptop -> tailnet -> web, port 80.
```

**Traffic flow for the validation curl request:**
1. My laptop resolves `web` via MagicDNS (`web.<tailnet-name>.ts.net`) or
   its Tailscale IP, using the native Tailscale app already running on the
   laptop.
2. My laptop opens a connection over the WireGuard tunnel directly to
   `web`'s tailscale sidecar (peer-to-peer where NAT allows it, relayed via
   Tailscale's DERP servers if a direct path can't be established — neither
   device needs a public IP for this to work).
3. Tailscale's control plane evaluates the ACL policy: `tag:client` →
   `tag:server:80` is explicitly allowed, so the connection is permitted.
4. The `web-tailscale` sidecar forwards the request to the `web` nginx
   container over the internal Docker network (`network_mode: service:web`
   makes them share a network namespace).
5. nginx serves the page; the response travels back over the same encrypted
   tunnel to my laptop.

## Setup and deployment

### Prerequisites
- Docker Desktop (Apple Silicon build, in my case) + Docker Compose v2
- A free Tailscale account, with the native app installed and connected on
  my laptop
- One auth key generated from the admin console (Settings → Keys →
  Generate auth key), tagged `tag:server`, for the `web` container.
  Recommended: mark it **reusable** and **ephemeral**.

### Steps

```bash
# 1. Clone this repo
git clone <this-repo-url>
cd tailscale-demo

# 2. Apply the ACL policy to your tailnet
#    Copy the contents of policy.hujson into:
#    https://login.tailscale.com/admin/acls

# 3. Tag your own laptop as tag:client
#    https://login.tailscale.com/admin/machines -> your laptop -> "..." ->
#    Edit tags -> add tag:client

# 4. Set up the web node's auth key
cp .env.example .env
# edit .env and paste in your TS_AUTHKEY_SERVER value

# 5. Bring the web node up
docker compose up -d

# 6. Confirm it registered (give it ~10-20s)
tailscale status

# 7. Run the validation script directly on your laptop
chmod +x scripts/validate.sh
./scripts/validate.sh
```

## How to validate that it works

`scripts/validate.sh` runs directly in my Mac's terminal (not via
`docker exec`, since my laptop is the client node, not a container) and
does three things, saving evidence to `validation-output/`:
1. Prints `tailscale status`, showing both my laptop and `web` online.
2. Resolves `web`'s tailnet IP via MagicDNS.
3. Curls the web service over the tailnet and captures the HTML response.

To see the ACL actually deny something, I temporarily removed the `acls`
block in `policy.hujson`, re-applied it, and re-ran the curl step — it
started timing out instead of resolving, since Tailscale defaults to
deny-all with no matching rule.

## Assumptions / prerequisites

- Assumes a personal Tailscale account with admin access to the ACL policy
  editor and the ability to tag devices.
- Assumes Docker has access to `/dev/net/tun` for the `web` container's
  sidecar (true by default on Docker Desktop for Mac).
- The auth key is treated as a secret and is **not** committed — only
  `.env.example` is checked in.

## What worked well

- Docker Compose's `network_mode: service:web` made it trivial to attach a
  Tailscale sidecar to an existing container without modifying the nginx
  image at all — a pattern that generalizes well to "put Tailscale in front
  of any existing service" for a customer conversation.
- Tag-based ACLs made the access pattern a single, readable rule instead of
  a sprawling list of per-device or per-user exceptions.
- Using my actual laptop as the client node made the whole thing feel much
  more real than two containers talking to each other — I could watch the
  device show up live in the admin console dashboard, which also made the
  underlying concepts (tailnet, tags, ACLs) click faster while I was
  learning them.

## What was difficult or surprising

- I initially got stuck with the Tailscale app hanging on "VPN starting" on
  my laptop. It turned out to be resolved by a macOS software update —
  worth knowing that OS-level VPN/network extension support can be
  version-sensitive.
- It's easy to accidentally leave a `ports:` mapping in a Compose file that
  quietly defeats the entire "private service" premise — worth calling out
  explicitly when explaining this to a customer, since it's a common
  mistake in real deployments too.
- Understanding the difference between the "tailnet" (the network) and
  "ACLs" (the permission layer on top of it) took a bit to click — two
  devices being on the same tailnet doesn't mean they can reach each other;
  the ACL policy is a separate, explicit authorization step.

## What I'd do differently with more time

- Add a subnet router node to expose an entire private CIDR (e.g. a whole
  Docker network or a simulated on-prem subnet) rather than just one
  service, and show `tailscale status` reflecting subnet routes.
- Add `tailscale serve` to terminate HTTPS with a real cert on the `web`
  node and show the difference between tailnet-only access (`serve`) and
  the fully public option (`funnel`), since explaining that distinction
  clearly is a common real customer question.
- Wire this into a GitHub Actions workflow that joins the tailnet as an
  ephemeral CI node and runs the validation curl automatically on every
  push, to demonstrate the CI/CD access pattern from the assignment's idea
  list as well.

## Where AI assistance was used

I used Claude to help me plan the project scope, generate the initial
Docker Compose / ACL policy / validation script scaffolding, and structure
this README. I also used it to talk through networking and Tailscale
concepts I was unfamiliar with (tailnets, MagicDNS, NAT traversal, ACLs) as
I worked through the assignment. I reviewed, tested, and adjusted the
configuration myself — including switching the client node from a second
container to my own laptop — before submitting.
