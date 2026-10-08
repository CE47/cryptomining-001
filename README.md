# CTIA Scenario Lab — cryptomining-001

A self-contained SOC analyst training scenario. Investigate it in Kibana using the
step-by-step guide, then write up and submit your findings.

## The scenario

An attacker who had obtained the credential of the `svc_backup` service account abused
it to open a network logon on a production server, ran a PowerShell downloader with an
encoded payload under a remote-execution service, and executed the mining binary that
downloader fetched. The server then resolved the mining pool's domain and began
reporting to it in small, perfectly periodic sessions.

Two synthetic, deterministic log sources are loaded into Elasticsearch:

| Data view | What it covers |
|---|---|
| `auth-*` | Windows security-style authentication events: logons, failed logons, logoffs, privilege assignment, lockouts, Kerberos pre-auth failures, and process creations with process name, parent and command line |
| `network-*` | Connection events between hosts and toward external peers: SMB, RPC, DNS queries and their answers, LDAP, HTTP/HTTPS, SSH, ICMP |

Timestamps are stored in UTC. Kibana displays them in your own timezone — read the
clock times off your own screen and judge the gaps between events, not the absolute
numbers.

---

## How to run the lab

### 1. Clone the repository

```bash
git clone https://github.com/CE47/cryptomining-001.git
cd cryptomining-001
```

### 2a. Windows — set up Docker Desktop

1. Install **WSL** (Windows Subsystem for Linux). In an elevated PowerShell window:

   ```powershell
   wsl --install
   ```

   Restart Windows when it asks, then run `wsl --install --no-distribution` again if
   needed. Verify with `wsl --status`.

2. Install **Docker Desktop for Windows** from <https://www.docker.com/products/docker-desktop/>.
   Let it finish installing WSL 2 backend updates, then launch Docker Desktop and
   wait until the whale icon reports **Engine running**.

### 2b. Linux / macOS — set up Docker

Install **Docker Desktop** (<https://www.docker.com/products/docker-desktop/>) or
Docker Engine with the Compose plugin, make sure it is running, and skip to step 3.

### 3. Build the lab

Double-click **`setup-lab.cmd`** (Windows), or run `./setup-lab.sh` in a terminal
(Linux / macOS).

The script builds and verifies everything in ten stages: it starts Elasticsearch and
Kibana in Docker, installs the index templates, imports the datasets, creates the
`auth` and `network` data views, and installs the detection rules that populate the
Alerts page. First run downloads over a gigabyte of images, so be patient. When it
finishes it prints:

```
The lab is ready.
Kibana        : http://localhost:5601
Kibana login  lab_kibana / LabKibana001
```

and it opens Kibana in your browser. Sign in with the lab credentials if prompted.
They are throwaway credentials and protect nothing.

### 4. Perform the investigation

Work in Kibana with the guide open beside you:

- **`guided-walkthrough.html`** — open it in any browser (no server, no internet
  needed). It is a card deck that walks you from an empty screen to a signed-off
  verdict, with screenshots taken from this exact lab, the investigation queries to
  run, and where to find each answer.
- The same content is in `guided-walkthrough.md` if you prefer plain text.
- The setup script also prints the investigation queries and the number of results
  each one must return — that is your reference sheet.

Useful starting points in Kibana: `Security → Alerts` (6 fired alerts, severities
**High** and **Critical**) and the `auth` / `network` data views under **Discover**.

### 5. Write it up and submit

The **`Write it up`** card in `guided-walkthrough.html` is your deliverable. It has
input boxes that start empty on purpose: fill in the report sections, check off the
figures you found against your own screen, enter your name and batch number, then
press **`EXPORT MY SUBMISSION`**.

A PDF of your typed report is built in your browser and saved to your **Downloads**
folder — nothing is uploaded. That PDF is your submission for this activity.

### 6. Clean up

When you have exported and submitted your report:

- **Windows:** double-click `teardown.cmd`
- **Linux / macOS:** run `./teardown.sh`

Both remove exactly what the setup created, named after this folder, and never touch
other Docker resources or other labs.

---

## Files in this repository

| File | Description |
|---|---|
| `README.md` | this file |
| `guided-walkthrough.html` | **the investigation guide and the write-up / submission form — open this in a browser** |
| `auth.ndjson` / `auth.json` | auth events (271 docs) and the `auth-*` index template |
| `network.ndjson` / `network.json` | network events (149 docs) and the `network-*` index template |
| `rule.json` / `rule-2.json` / `rule-3.json` | the three detection rules the lab installs, so the Alerts page is not empty |
| `setup-lab.cmd` / `setup-lab.sh` | **Windows / Linux-macOS.** One-click lab build, fully verified |
| `teardown.cmd` / `teardown.sh` | **Windows / Linux-macOS.** Safe, scenario-scoped, idempotent removal |

`docker-compose.yml` is generated by the setup script; delete it and re-run setup to
rebuild it.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `docker` is not recognized | Install and start Docker Desktop, then reopen the terminal |
| Setup fails at the Docker check | Docker is not running — launch Docker Desktop and wait for **Engine running** |
| Setup fails later with a container error | `docker logs cryptomining-001-elasticsearch` |
| Kibana shows no data | Check the time range picker covers `2026-09-22 00:00` → `2026-09-22 23:59` (UTC) |
| Want a clean slate | Run `teardown.cmd` / `./teardown.sh`, then setup again |