# Zephyrus Implementation Guide

**Hyperledger Fabric Blockchain for Decentralized Digital Twin in UAV Swarms**

---

Multi-host Deployment on 4 Raspberry Pi 4

**Sergio Frejo-Martin**
University of Extremadura
Department of Computer and Telematics Systems Engineering
March 2026

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Project Structure](#2-project-structure)
3. [Step-by-Step Deployment Guide](#3-step-by-step-deployment-guide)
4. [The Chaincode: Digital Twin Logic](#4-the-chaincode-digital-twin-logic)
5. [Simulation Scripts](#5-simulation-scripts)
6. [Performance Considerations on Raspberry Pi](#6-performance-considerations-on-raspberry-pi)
7. [Operations and Maintenance](#7-operations-and-maintenance)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Architecture Overview

This guide describes the complete implementation of a Hyperledger Fabric network deployed across 4 Raspberry Pi 4 devices, designed to maintain a decentralized Digital Twin of an unmanned aerial vehicle (UAV) swarm. The architecture follows the three-layer model defined in the research paper.

### 1.1. Three-Layer Architecture

**Physical Layer:** Composed of 4 Raspberry Pi 4 devices, each representing a node in the swarm. The physical UAVs generate telemetry data (battery, CPU, RAM, GPS position, link quality) that is recorded on the blockchain.

**Ledger Layer / Digital Twin (DT Layer):** Implemented through Hyperledger Fabric's World State (LevelDB key-value database). Each UAV has a digital descriptor that replicates its physical state, including telemetry, assigned roles, operational status, and associated Docker services.

**Control Layer:** Materialized through smart contracts (chaincode) written in Go. It contains the logic for telemetry management, role assignment, and handover coordination between UAVs.

### 1.2. Raspberry Pi Assignment

The following table shows the concrete assignment of each Raspberry Pi to Fabric network roles and their correspondence with the concepts defined in the paper:

| Raspberry Pi | Hostname    | Fabric Role          | Paper Role                    | Docker Components                          |
|:-------------|:------------|:---------------------|:------------------------------|:-------------------------------------------|
| UAV-1        | uav-1.local | Orderer (Raft) + CAs | Ordering node + MSP/CA        | orderer, ca-orderer, ca-org1, ca-org2      |
| UAV-2        | uav-2.local | Peer (SwarmOrg1)     | Endorsing/Committing peer     | peer0.org1, cli-org1                       |
| UAV-3        | uav-3.local | Peer (SwarmOrg2)     | Endorsing/Committing peer     | peer0.org2, cli-org2                       |
| UAV-4        | uav-4.local | Client (CLI)         | Swarm Agent (pure client)     | cli-agent                                  |

### 1.3. Network Topology

- **Networking:** Bridge networking on each Raspberry Pi with `extra_hosts` for cross-node name resolution.
- **Channel:** `swarm-management` with an AND endorsement policy (both organizations must approve each transaction).
- **Consensus:** Raft with a single orderer (on UAV-1) for simplicity. Configurable to multi-orderer for greater fault tolerance.
- **Name resolution:** Avahi/mDNS for automatic discovery (`.local`), with static IPs as fallback in the `.env` file.

---

## 2. Project Structure

The project follows a modular structure that clearly separates configuration, Docker compose files, chaincode, deployment scripts, benchmarking, and documentation:

```
uav-fabric-network/
├── config/
│   ├── crypto-config.yaml            # Cryptogen configuration
│   ├── configtx.yaml                 # Organization and orderer configuration
│   └── configtx-channel.yaml         # Channel-specific configuration
├── compose/
│   ├── .env                          # Environment variables (IPs, versions)
│   ├── docker-compose-uav1.yaml      # Orderer + CAs
│   ├── docker-compose-uav2.yaml      # Peer Org1 + CLI
│   ├── docker-compose-uav3.yaml      # Peer Org2 + CLI
│   └── docker-compose-uav4.yaml      # Client (Swarm Agent)
├── chaincode/
│   └── swarm-management/
│       ├── go.mod
│       ├── main.go
│       └── chaincode/
│           ├── smartcontract.go       # 3 functional families (~1200 lines)
│           └── smartcontract_test.go  # Unit tests
├── scripts/
│   ├── env.sh                        # Shared variables
│   ├── 00-resolve-hosts.sh           # mDNS → IP resolution
│   ├── 01-generate-crypto.sh         # Cryptographic material
│   ├── 02-generate-channel-artifacts.sh  # Channel genesis block
│   ├── 03-distribute.sh              # Distribution to the Pis
│   ├── 04-start-network.sh           # Container startup
│   ├── 05-create-channel.sh          # Channel creation + anchor peers
│   ├── 06-deploy-chaincode.sh        # Packaging, installation, and commit
│   ├── 07-init-ledger.sh             # Digital Twin initialization
│   ├── teardown.sh                   # Full cleanup
│   ├── status.sh                     # Network status
│   ├── start_blockchain.sh           # Full startup orchestration
│   ├── sim-env.sh                    # Simulation variables
│   ├── sim-telemetry-update.sh       # Telemetry simulation
│   ├── sim-handover-flow.sh          # Complete handover flow
│   ├── sim-role-assignment.sh        # Role management
│   ├── sim-concurrent-claim.sh       # MVCC conflict demonstration
│   ├── sim-full-scenario.sh          # Complete end-to-end scenario
│   ├── query-dt.sh                   # Digital Twin state query
│   ├── bench-env.sh                  # Benchmark environment variables
│   ├── bench-01-latency.sh           # Latency benchmark
│   ├── bench-02-throughput.sh        # Throughput benchmark
│   ├── bench-03-handover.sh          # Handover benchmark
│   ├── bench-04-mvcc.sh              # MVCC conflict benchmark
│   ├── bench-05-resources.sh         # Resource usage benchmark
│   ├── run-benchmarks.sh             # Run all benchmarks
│   └── logs/                         # Script execution logs
├── results/                          # Benchmark results (CSV)
│   ├── bench-01-latency.csv
│   ├── bench-02-throughput.csv
│   ├── bench-03-handover.csv
│   ├── bench-04-mvcc.csv
│   ├── bench-resources-UAV-{1..4}.csv
│   └── figures/                      # Generated figures
├── logs/                             # Runtime logs
├── organizations/                    # (generated) Cryptographic material
├── channel-artifacts/                # (generated) Channel artifacts
└── docs/
    └── raspberry-setup.md            # Raspberry Pi setup instructions
```

The `organizations/`, `channel-artifacts/`, and `logs/` directories are generated automatically during the deployment process and should not be included in version control.

---

## 3. Step-by-Step Deployment Guide

The following steps describe how to deploy the complete network. All commands are executed from UAV-1 (master node) unless otherwise noted.

### 3.0. Step 0: Initial Setup

Clone or copy the `uav-fabric-network` project to UAV-1's home directory:

```bash
# Clone the repository (or copy manually)
cd ~
git clone <repository-url> uav-fabric-network
cd uav-fabric-network
```

Verify that Fabric binaries are available:

```bash
peer version
orderer version
configtxgen --version
```

### 3.1. Step 1: Resolve Hosts

```bash
cd ~/uav-fabric-network
bash scripts/00-resolve-hosts.sh
```

This script uses `avahi-resolve` to translate mDNS names (`uav-1.local`, `uav-2.local`, etc.) into concrete IP addresses. The resolved IPs are written to `compose/.env`, which is used by all docker-compose files as the source of environment variables. If any host does not respond, the script will report the error.

### 3.2. Step 2: Generate Cryptographic Material

```bash
bash scripts/01-generate-crypto.sh
```

Uses the `cryptogen` tool with the configuration defined in `config/crypto-config.yaml` to generate X.509 certificates for all organizations, peers, orderers, and admin users. The material is deposited in the `organizations/` directory. This includes:

- Root certificates (CA) for each organization (SwarmOrg1, SwarmOrg2, OrdererOrg)
- TLS certificates for secure inter-node communication
- Private keys and identity certificates for peers, orderers, and admin users
- MSP (Membership Service Provider) directories with the structure required by Fabric

### 3.3. Step 3: Generate Channel Artifacts

```bash
bash scripts/02-generate-channel-artifacts.sh
```

Runs `configtxgen` using the configuration from `config/configtx.yaml` and `config/configtx-channel.yaml` to create the genesis block for the `swarm-management` channel. This block defines the participating organizations, endorsement policies (AND), Raft consensus parameters, and initial anchor peers. The resulting artifacts are stored in `channel-artifacts/`.

### 3.4. Step 4: Distribute Files to the Raspberry Pis

```bash
bash scripts/03-distribute.sh
```

This script copies the necessary files to each Raspberry Pi via SCP (or rsync) according to its role:

- **UAV-1:** Orderer and CAs cryptographic material, `docker-compose-uav1.yaml`
- **UAV-2:** SwarmOrg1 cryptographic material, `docker-compose-uav2.yaml`, chaincode
- **UAV-3:** SwarmOrg2 cryptographic material, `docker-compose-uav3.yaml`, chaincode
- **UAV-4:** Client cryptographic material, `docker-compose-uav4.yaml`

### 3.5. Step 5: Start the Network

```bash
bash scripts/04-start-network.sh
```

Starts the Docker containers in the correct order to ensure dependencies are properly resolved:

1. **First:** Orderer and CAs on UAV-1 (`docker-compose-uav1.yaml`)
2. **Second:** SwarmOrg1 Peer on UAV-2 (`docker-compose-uav2.yaml`)
3. **Third:** SwarmOrg2 Peer on UAV-3 (`docker-compose-uav3.yaml`)
4. **Fourth:** Swarm Agent Client on UAV-4 (`docker-compose-uav4.yaml`)

The script waits for each service to be fully operational before continuing with the next, verifying TLS connectivity.

### 3.6. Step 6: Create the Channel

```bash
bash scripts/05-create-channel.sh
```

Performs the following operations in sequence:

1. Uses `osnadmin` to join the orderer to the `swarm-management` channel
2. Runs `peer channel join` on UAV-2 (`peer0.org1`) to join SwarmOrg1 to the channel
3. Runs `peer channel join` on UAV-3 (`peer0.org2`) to join SwarmOrg2 to the channel
4. Configures anchor peers for both organizations via `peer channel update`

### 3.7. Step 7: Deploy the Chaincode

```bash
bash scripts/06-deploy-chaincode.sh
```

Executes the complete Fabric chaincode lifecycle deployment:

1. **Packaging:** `peer lifecycle chaincode package` of the `swarm-management` chaincode
2. **Installation:** `peer lifecycle chaincode install` on both peers (Org1 and Org2)
3. **Approval:** `peer lifecycle chaincode approveformyorg` by each organization
4. **Commit:** `peer lifecycle chaincode commit` with signatures from both organizations
5. **Verification:** `peer lifecycle chaincode querycommitted` to confirm deployment

### 3.8. Step 8: Initialize the Digital Twin

```bash
bash scripts/07-init-ledger.sh
```

Invokes the `InitLedger` chaincode function, which creates the initial descriptors for the 4 UAVs in the World State. Each descriptor includes: unique identifier, operational status (`ACTIVE`/`STANDBY`), initial telemetry, assigned blockchain roles, and position.

### 3.9. Step 9: Verify the Deployment

```bash
bash scripts/status.sh
```

Verifies the complete network status: active Docker containers on each node, peer states, created channel, and deployed/invocable chaincode. If any component is not responding, the script will indicate exactly what is failing.

---

## 4. The Chaincode: Digital Twin Logic

The `swarm-management` chaincode implements all the business logic of the decentralized Digital Twin. It is written in Go and organized into three functional families that cover the UAV swarm management requirements.

### 4.1. Family 1: Telemetry and DT Maintenance

This family manages the lifecycle of UAV descriptors and the continuous update of telemetry data in the World State.

| Function                  | Description                                                           | Main Parameters                                       |
|:--------------------------|:----------------------------------------------------------------------|:------------------------------------------------------|
| `InitLedger`              | Creates initial descriptors for the 4 UAVs with baseline telemetry    | None (predefined data)                                |
| `RegisterUAV`             | Registers a new UAV in the Digital Twin                               | id, status, position, telemetry                       |
| `UpdateTelemetry`         | Updates sensor data for a UAV                                         | id, battery, cpu, ram, storage, linkQuality, position |
| `GetUAVState`             | Queries the complete state of a specific UAV                          | id                                                    |
| `GetAllUAVs`              | Returns the state of all registered UAVs                              | None                                                  |
| `GetUAVsByStatus`         | Filters UAVs by operational status (`ACTIVE`, `STANDBY`, `DEPLETED`)  | status                                                |
| `CheckDepletionThreshold` | Automatically detects if a UAV has reached the depletion threshold    | id, threshold                                         |

The `CheckDepletionThreshold` function is fundamental to the handover mechanism: when a UAV's battery drops below the configured threshold, it automatically changes its status to `DEPLETED` and emits a `DepletionDetected` event that triggers the replacement process.

### 4.2. Family 2: Service and Role Management

Manages role assignment at both the Docker service level and the blockchain network participation level.

| Function                   | Description                                                                              |
|:---------------------------|:-----------------------------------------------------------------------------------------|
| `AssignServiceRole`        | Assigns the `SERVICE_HOST` role to a UAV, indicating the Docker image of the service to run |
| `RevokeServiceRole`        | Revokes a UAV's service role, typically during a handover                                 |
| `AssignBlockchainRole`     | Assigns a blockchain role: `ORDERER`, `ENDORSER`, `COMMITTER`, or `CLIENT`               |
| `GetActiveRoleAssignments` | Returns all active role assignments in the swarm                                         |
| `AssignTargetPosition`     | Assigns a target position to a UAV for flight coordination                               |

The separation between service roles and blockchain roles enables flexible management. A UAV can simultaneously be an endorser (blockchain role) and host an image processing service (service role).

### 4.3. Family 3: Handover Coordination

Implements the protocol for transferring responsibilities between a depleted UAV and its replacement. The handover follows a multi-phase flow designed to guarantee consistency:

1. **INITIATED:** A UAV with `DEPLETED` status is detected and the handover process begins.
2. **REPLACEMENT_SELECTED:** A UAV in `STANDBY` status is selected as the replacement.
3. **MIGRATING:** Docker service migration from the depleted UAV to the replacement begins.
4. **COMPLETED:** Migration successful. Roles and services are fully transferred.
5. **FAILED:** Migration fails. States are reverted to the previous checkpoint.

| Function            | Phase                    | Description                                                   |
|:--------------------|:-------------------------|:--------------------------------------------------------------|
| `InitiateHandover`  | &rarr; INITIATED         | Creates the handover record and marks the UAV as in-process   |
| `SelectReplacement` | &rarr; REPLACEMENT_SELECTED | Selects the replacement UAV and marks it as a candidate    |
| `StartMigration`    | &rarr; MIGRATING         | Initiates service transfer between UAVs                       |
| `CompleteMigration` | &rarr; COMPLETED         | Finalizes the handover, transfers roles, and updates states   |
| `FailHandover`      | &rarr; FAILED            | Reverts the handover and restores previous states             |
| `GetHandoverRecord` | Query                    | Retrieves the details of a specific handover                  |
| `GetActiveHandovers`| Query                    | Lists all in-progress handovers (not completed/failed)        |
| `GetHandoverHistory`| Query                    | Complete history of all handovers performed                   |

### 4.4. Chaincode Events

The chaincode emits events at key lifecycle moments, allowing Swarm Agents (clients) to react in real time via event listeners:

| Event                | Emission Trigger                           | Included Data                    |
|:---------------------|:-------------------------------------------|:---------------------------------|
| `DepletionDetected`  | UAV reaches depletion threshold            | uavId, batteryLevel, threshold   |
| `HandoverInitiated`  | A handover process is started              | handoverId, depletedUavId        |
| `ReplacementSelected`| A replacement UAV is selected              | handoverId, replacementUavId     |
| `MigrationStarted`   | Service migration begins                   | handoverId, serviceImage         |
| `HandoverCompleted`  | Handover finishes successfully             | handoverId, newActiveUavId       |
| `HandoverFailed`     | Handover fails, states reverted            | handoverId, reason               |
| `RoleAssigned`       | A new role is assigned to a UAV            | uavId, roleType, roleDetails    |
| `RoleRevoked`        | A role is revoked from a UAV              | uavId, roleType                  |

### 4.5. Composite Keys and Efficient Queries

To avoid the need for CouchDB (which would significantly increase resource consumption on Raspberry Pi), the chaincode uses Fabric composite keys that enable efficient queries on LevelDB:

| Composite Key          | Format                          | Enables Querying                          |
|:-----------------------|:--------------------------------|:------------------------------------------|
| `uav~status~id`       | `uav~ACTIVE~UAV-001`           | All UAVs with a specific status           |
| `handover~phase~id`   | `handover~MIGRATING~HO-001`    | Handovers in a specific phase             |
| `role~uavid~type`     | `role~UAV-001~ENDORSER`        | Roles assigned to a specific UAV          |

Composite keys are created with `stub.CreateCompositeKey()` and queried with `stub.GetStateByPartialCompositeKey()`. This mechanism allows partial queries (by prefix) without requiring a database with rich query support, keeping the footprint minimal on edge devices.

---

## 5. Simulation Scripts

The simulation scripts allow demonstrating and validating the Digital Twin's operation without the need for physical UAVs. All scripts run inside the CLI containers.

### 5.1. Telemetry Update

```bash
# From UAV-2 (inside the Org1 CLI container):
docker exec cli-org1 bash /scripts/sim-telemetry-update.sh 5
```

Generates 5 sequential telemetry updates for the UAVs, simulating variations in battery, CPU, RAM, storage, link quality, and GPS position. Values are generated with realistic random variations, progressively decrementing battery to simulate energy consumption during flight.

### 5.2. Complete Handover Flow

```bash
docker exec cli-org1 bash /scripts/sim-handover-flow.sh
```

Executes a complete end-to-end handover flow:

1. Reduces an `ACTIVE` UAV's battery below the threshold (20%)
2. Invokes `CheckDepletionThreshold`, which changes the status to `DEPLETED`
3. Initiates the handover with `InitiateHandover` (phase `INITIATED`)
4. Selects a `STANDBY` UAV as a replacement (phase `REPLACEMENT_SELECTED`)
5. Simulates Docker service migration (phase `MIGRATING`)
6. Completes the handover: the replacement becomes `ACTIVE`, the original becomes `RETIRED` (phase `COMPLETED`)

### 5.3. Role Assignment

```bash
docker exec cli-org1 bash /scripts/sim-role-assignment.sh
```

Demonstrates the assignment and revocation of both Docker service roles and blockchain participation roles. Assigns `SERVICE_HOST` with a video processing image to a UAV, then assigns blockchain roles (`ENDORSER`, `COMMITTER`), and finally revokes the service to simulate deassignment.

### 5.4. MVCC Conflict Demonstration

```bash
docker exec cli-org1 bash /scripts/sim-concurrent-claim.sh
```

This script is essential for validating one of the key contributions of the paper: the prevention of conflicting assignments through Fabric's native MVCC (Multi-Version Concurrency Control) mechanism.

The script launches two simultaneous transactions attempting to claim the same standby UAV as a replacement for two different handovers. Thanks to Fabric's Execute-Order-Validate mechanism, only the first validated transaction will succeed. The second will receive an `MVCC_READ_CONFLICT` error because the state version it read during the execution (simulation) phase will have already been modified by the time the validation phase occurs.

### 5.5. Complete End-to-End Scenario

```bash
docker exec cli-org1 bash /scripts/sim-full-scenario.sh
```

Executes a complete scenario that combines all operations: swarm initialization, periodic telemetry updates, service assignment, depletion detection, complete handover with migration, MVCC conflict demonstration, and final Digital Twin state query. This is the best comprehensive demonstration of Zephyrus.

### 5.6. Digital Twin State Query

```bash
# Full state query
docker exec cli-org1 bash /scripts/query-dt.sh full

# Active UAVs only
docker exec cli-org1 bash /scripts/query-dt.sh active

# Specific UAV state
docker exec cli-org1 bash /scripts/query-dt.sh uav UAV-001

# Active handovers
docker exec cli-org1 bash /scripts/query-dt.sh handovers
```

A versatile query tool that allows inspecting any aspect of the Digital Twin stored in the World State.

---

## 6. Performance Considerations on Raspberry Pi

Deployment on Raspberry Pi 4 (4GB RAM, ARM Cortex-A72 quad-core) imposes significant resource constraints. The configuration is optimized to maximize stability and minimize consumption.

### 6.1. Memory Limits per Container

| Container                    | Memory Limit | Justification                                      |
|:-----------------------------|:-------------|:---------------------------------------------------|
| Orderer                      | 512 MB       | Block processing and Raft consensus                |
| Peer (endorsing/committing)  | 768 MB       | Chaincode simulation + validation + LevelDB        |
| Fabric CA                    | 256 MB       | Lightweight cryptographic operations               |
| CLI / Client                 | 512 MB       | Transaction construction and submission            |

### 6.2. Applied Optimizations

- **LevelDB instead of CouchDB:** Drastically reduces memory and disk consumption. Rich queries are replaced by composite keys.
- **BatchTimeout:** 2 seconds. Configured for the edge context.
- **MaxMessageCount:** 10 transactions per block. Balances latency and throughput.
- **Log rotation enabled:** Maximum 10 MB per file, 3 rotated files. Prevents filling the SD card.
- **Single orderer Raft:** Minimizes consensus overhead. Extensible to 3 orderers if more nodes are available.

### 6.3. Expected Performance Metrics

- **Transaction latency:** 2-5 seconds on Raspberry Pi 4 (based on similar ARM64 deployments).
- **Estimated throughput:** 5-15 transactions per second (depending on chaincode complexity).
- **Docker image pull time (first time):** 5-10 minutes per image on ARM64 (depends on connection).
- **Full network startup:** 2-4 minutes from container start to channel verification.

---

## 7. Operations and Maintenance

### 7.1. Verify Network Status

```bash
bash scripts/status.sh
```

Shows the status of all Docker containers on each node, connectivity between peers and orderer, the active channel, and the deployed chaincode version.

### 7.2. Stop and Clean Up the Network

```bash
# Stop containers (preserves data)
bash scripts/teardown.sh

# Full cleanup (removes crypto, artifacts, and volumes)
bash scripts/teardown.sh --full
```

The `--full` option removes all generated material (`organizations/`, `channel-artifacts/`) and Docker volumes, leaving the project ready for a clean deployment.

### 7.3. Update the Chaincode

To deploy a new version of the chaincode after modifying the code:

1. Modify the code in `chaincode/swarm-management/chaincode/smartcontract.go`
2. Increment the version and sequence in `scripts/06-deploy-chaincode.sh` (`CC_VERSION` and `CC_SEQUENCE`)
3. Run: `bash scripts/06-deploy-chaincode.sh`

Fabric requires both organizations to approve the new version before committing, ensuring consensus on changes.

### 7.4. Log Inspection

```bash
# View the last 100 orderer logs
docker logs orderer.uav-network.local --tail 100

# Follow peer logs in real time
docker logs -f peer0.org1.uav-network.local

# CA logs
docker logs ca-org1 --tail 50
```

### 7.5. Adding a New UAV to the Swarm

To add a new UAV to the Digital Twin:

1. Register the UAV in the chaincode: invoke `RegisterUAV` with the new device's data.
2. (Optional) If the new UAV will also be a peer in the Fabric network, generate its cryptographic material, create a new docker-compose file, and join it to the channel.

---

## 8. Troubleshooting

Below are the most common issues encountered during deployment and operation of the network, along with their solutions.

**"transport: authentication handshake failed"**
TLS handshake error. Generally caused by a mismatch between TLS certificates and the SANs (Subject Alternative Names) configured in `crypto-config.yaml`. Verify that the hostnames in `crypto-config.yaml` match exactly those used by the Docker containers.

**Container does not start**
Run `docker logs <container-name>` to identify the error. The most common causes are: incorrect IPs in the `.env` file, ports already in use, or missing cryptographic material (the `organizations/` directory was not distributed correctly).

**Channel creation fails**
Verify that the orderer is running and accessible from the node executing the command. Check connectivity: `docker exec cli-org1 ping orderer.uav-network.local`. Verify that the genesis block was generated correctly.

**Timeout during chaincode installation**
Raspberry Pis are significantly slower than conventional servers when compiling Go. Increase the timeout in environment variables: `CORE_PEER_CLIENT_CONNTIMEOUT=120s` and `CORE_PEER_DELIVERYTIMEOUT=120s`.

**MVCC_READ_CONFLICT**
This error is expected when concurrent writes target the same keys. It is not a bug: it is Fabric's consistency protection mechanism. The solution is to retry the transaction from the client.

**Docker pull fails**
Verify the node's internet connection. Confirm that the Docker images used are available for the ARM64 architecture (`linux/arm64`). Official Hyperledger Fabric images support ARM64 since version 2.5.x.

**mDNS resolution fails**
Check that the `avahi-daemon` service is active on all nodes: `systemctl status avahi-daemon`. If Avahi is unavailable, configure static IPs manually in `compose/.env`.

**Error "chaincode definition not agreed to"**
Both organizations must approve the chaincode definition before commit. Verify with `peer lifecycle chaincode checkcommitreadiness` that both appear as `true`.

**Disk space shortage (SD card)**
Docker images and volumes can consume several GB. Use `docker system prune` to clean up unused images and containers. Consider using a 64GB or larger SD card.
