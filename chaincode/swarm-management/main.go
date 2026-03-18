// SPDX-License-Identifier: Apache-2.0

// Package main is the entry point for the UAV Swarm Digital Twin chaincode.
// It initializes the SmartContract and starts the chaincode process.
package main

import (
	"log"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
	cc "github.com/spilab/swarm-management/chaincode"
)

func main() {
	swarmChaincode, err := contractapi.NewChaincode(&cc.SmartContract{})
	if err != nil {
		log.Panicf("Error creating swarm-management chaincode: %v", err)
	}

	swarmChaincode.Info.Title = "UAV Swarm Digital Twin"
	swarmChaincode.Info.Version = "1.0.0"
	swarmChaincode.Info.Description = "Chaincode for managing UAV swarm Digital Twin: telemetry, service roles, and handover coordination"

	if err := swarmChaincode.Start(); err != nil {
		log.Panicf("Error starting swarm-management chaincode: %v", err)
	}
}
