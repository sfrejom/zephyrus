# Preparation of Raspberry Pi Nodes for Deployment

This guide describes the procedure required to prepare four **Raspberry Pi** devices running **Raspberry Pi OS Lite 64-bit** for the installation of the dependencies needed to support the decentralised digital-twin infrastructure proposed in the paper. The instructions assume that each board is already connected to the local network and that local name resolution via *mDNS* is operational (e.g., `uav-1.local`). Commands requiring administrative privileges should be executed with `sudo`.


## 1 Connectivity Verification

Before proceeding with software installation, verify that each node can be reached via its host name:

```bash
ping uav-1.local
ping uav-2.local
ping uav-3.local
ping uav-4.local
```

Successful responses indicate that the devices are visible on the network and that their names are resolvable.

## 2 Remote Access via SSH

Connect to one of the nodes using **SSH**. In the following steps, the login user is assumed to be `spilab` and the target host is `uav-2.local`:

```bash
ssh spilab@uav-2.local
```

The subsequent commands are executed within this SSH session.

## 3 Operating System Update

Update the package indices and install the latest available packages. Afterwards, reboot the device so that any relevant updates take effect:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

After the reboot, re-establish the SSH connection and continue with the remaining steps.

## 4 Installation of Essential Tools

Install the required system, networking, monitoring and Python-related packages:

```bash
sudo apt install -y \
  git curl wget jq vim tmux htop btop tree unzip zip \
  net-tools iproute2 dnsutils avahi-daemon \
  iperf3 tcpdump ethtool chrony rsync python3 python3-venv python3-pip \
  sysstat iotop dstat
```

### Time Configuration

Set the system time zone and enable both the time-synchronisation and *mDNS* services:

```bash
sudo timedatectl set-timezone Europe/Madrid
sudo systemctl enable --now chrony
sudo systemctl enable --now avahi-daemon
```

## 5 Resolving IP Conflicts between Avahi and Docker

Adjust the *Avahi* configuration to prevent conflicts between the Raspberry Pi network interface and Docker-created interfaces:

1. Edit the configuration file:

   ```bash
   sudo nano /etc/avahi/avahi-daemon.conf
   ```

2. Apply the following changes in `avahi-daemon.conf`:

   ```ini
   [server]
   use-ipv4=yes
   allow-interfaces=w1an0
   deny-interfaces=docker0
   ```

3. Restart the *Avahi* service:

   ```bash
   sudo systemctl restart avahi-daemon
   ```

## 6 System Information Checks

Confirm the host configuration and time-synchronisation status:

```bash
hostnamectl
ip a
timedatectl
chronyc tracking
```

## 7 Removal of Legacy Container Engines

Remove any previously installed container runtimes that may interfere with the intended Docker installation:

```bash
sudo apt remove -y docker.io docker-compose docker-doc podman-docker containerd runc || true
```

## 8 Docker Installation

### 8.1 Set Up the Official Repository

Ensure that certificate packages are present, retrieve Docker's GPG key, and add the Docker repository:

```bash
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
```

### 8.2 Install Docker Engine and Utilities

Install Docker and the associated tooling:

```bash
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER
sudo chmod 666 /var/run/docker.sock
sudo systemctl enable docker
sudo systemctl start docker
```

At this point, close the session and log in again if necessary, or reboot if problems are encountered, so that group-membership changes can take effect.

Verify the installation:

```bash
docker version
docker compose version
docker run --rm hello-world
```

### 8.3 Daemon Configuration

Configure Docker logging to limit log-file growth:

```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
EOF

sudo systemctl restart docker
```

## 9 Directory Structure for Experiments

Create directories to organise experiment logs, scripts and results:

```bash
mkdir -p ~/experiments/logs ~/experiments/scripts ~/experiments/results
```

## 10 Development Tools Installation

Install **Go**, **Node.js** and **NPM**:

```bash
sudo apt install -y golang nodejs npm
go version
node -v
npm -v
```

## 11 Hyperledger Fabric Installation

### 11.1 Retrieve the Installation Script

Create the working directory and download the official Fabric installation script:

```bash
mkdir -p $HOME/go/src/github.com/spilab
cd $HOME/go/src/github.com/spilab
curl -sSLO https://raw.githubusercontent.com/hyperledger/fabric/main/scripts/install-fabric.sh
chmod +x install-fabric.sh
```

Ensure that the user belongs to the `docker` group, that the Docker socket is accessible, and that the daemon is restarted before executing the installer:

```bash
sudo usermod -aG docker ${USER}
sudo chmod 666 /var/run/docker.sock
sudo systemctl restart docker
```

### 11.2 Execute Installation

Run the installer to retrieve the Docker images, binaries and sample networks:

```bash
./install-fabric.sh docker binary samples
```

### 11.3 Environment Configuration

Append the Fabric binaries and configuration directory to the shell environment:

```bash
echo 'export PATH=$HOME/go/src/github.com/spilab/fabric-samples/bin:$PATH' >> ~/.bashrc
echo 'export FABRIC_CFG_PATH=$HOME/go/src/github.com/spilab/fabric-samples/config' >> ~/.bashrc
source ~/.bashrc
```

### 11.4 Version Validation

Validate the installed Hyperledger Fabric tooling:

```bash
peer version
orderer version
configtxgen --version
which osnadmin
fabric-ca-client version
```

## 12 Testing the Fabric Sample Network

Navigate to the `test-network` directory, bring up the network, inspect the running containers, and then tear the network down:

```bash
cd $HOME/go/src/github.com/spilab/fabric-samples/test-network
./network.sh up
docker ps
./network.sh down
```

## 13 Final Verification

Perform the final verification checks:

```bash
hostnamectl
uname -m
cat /etc/os-release
docker version
docker compose version
python3 --version
jq --version
chronyc tracking
iperf3 --version

peer version
orderer version
configtxgen --version
fabric-ca-client version
```

These checks confirm that the operating system, architecture, container infrastructure, network utilities and Hyperledger Fabric tooling are installed and accessible. Once completed, the Raspberry Pi nodes are ready to support the decentralised management and digital-twin architecture described in the accompanying research.