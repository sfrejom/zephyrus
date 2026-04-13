// SPDX-License-Identifier: Apache-2.0

// Package chaincode implements the UAV Swarm Digital Twin smart contract for
// Hyperledger Fabric 2.5. It provides three functional families:
//
//  1. Telemetry & Digital Twin Maintenance – registering UAVs, updating sensor
//     data, and monitoring depletion thresholds.
//  2. Service Management – assigning and revoking blockchain/service roles.
//  3. Handover Coordination – orchestrating the multi-phase replacement of a
//     depleted UAV by a standby unit.
//
// The contract is designed for a permissioned network of Raspberry Pi 4 nodes
// acting as a UAV swarm, where Fabric's MVCC conflict detection naturally
// prevents concurrent role-claim races.
package chaincode

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ---------------------------------------------------------------------------
// Data Structures
// ---------------------------------------------------------------------------

// UAVDescriptor represents a single UAV in the Digital Twin world state.
type UAVDescriptor struct {
	DocType        string   `json:"docType"`
	UAVID          string   `json:"uavId"`
	Status         string   `json:"status"`
	BatteryLevel   float64  `json:"batteryLevel"`
	CPUUsage       float64  `json:"cpuUsage"`
	RAMUsage       float64  `json:"ramUsage"`
	StorageUsage   float64  `json:"storageUsage"`
	LinkQuality    float64  `json:"linkQuality"`
	Position       Position `json:"position"`
	BlockchainRole string   `json:"blockchainRole"`
	ServiceRole    string   `json:"serviceRole"`
	AssignedImage  string   `json:"assignedImage"`
	LastUpdate     string   `json:"lastUpdate"`
	OrgMSP         string   `json:"orgMsp"`
}

// Position is a WGS-84 coordinate with altitude (metres above ground).
type Position struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
	Altitude  float64 `json:"altitude"`
}

// HandoverRecord tracks one full UAV replacement lifecycle.
type HandoverRecord struct {
	DocType        string   `json:"docType"`
	HandoverID     string   `json:"handoverId"`
	DepletedUAV    string   `json:"depletedUav"`
	ReplacementUAV string   `json:"replacementUav"`
	Phase          string   `json:"phase"`
	InitiatedAt    string   `json:"initiatedAt"`
	CompletedAt    string   `json:"completedAt"`
	ServiceImage   string   `json:"serviceImage"`
	TargetPosition Position `json:"targetPosition"`
	Notes          string   `json:"notes"`
}

// RoleAssignment records the assignment of a blockchain or service role to a UAV.
type RoleAssignment struct {
	DocType      string `json:"docType"`
	AssignmentID string `json:"assignmentId"`
	UAVID        string `json:"uavId"`
	RoleType     string `json:"roleType"`
	RoleName     string `json:"roleName"`
	AssignedAt   string `json:"assignedAt"`
	RevokedAt    string `json:"revokedAt"`
	Active       bool   `json:"active"`
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

// UAV statuses
const (
	StatusActive    = "ACTIVE"
	StatusDepleted  = "DEPLETED"
	StatusStandby   = "STANDBY"
	StatusReplacing = "REPLACING"
	StatusOffline   = "OFFLINE"
)

// Blockchain roles
const (
	RoleOrderer  = "ORDERER"
	RoleEndorser = "ENDORSER"
	RoleCommitter = "COMMITTER"
	RoleClient   = "CLIENT"
)

// Service roles
const (
	ServiceHost    = "SERVICE_HOST"
	ServiceStandby = "STANDBY"
	ServiceNone    = "NONE"
)

// Role types
const (
	RoleTypeBlockchain = "BLOCKCHAIN"
	RoleTypeService    = "SERVICE"
)

// Handover phases
const (
	PhaseInitiated           = "INITIATED"
	PhaseReplacementSelected = "REPLACEMENT_SELECTED"
	PhaseMigrating           = "MIGRATING"
	PhaseCompleted           = "COMPLETED"
	PhaseFailed              = "FAILED"
)

// Chaincode event names
const (
	EventHandoverInitiated  = "HandoverInitiated"
	EventHandoverCompleted  = "HandoverCompleted"
	EventDepletionDetected  = "DepletionDetected"
	EventRoleAssigned       = "RoleAssigned"
	EventRoleRevoked        = "RoleRevoked"
	EventMigrationStarted   = "MigrationStarted"
	EventReplacementSelected = "ReplacementSelected"
	EventHandoverFailed     = "HandoverFailed"
)

// ---------------------------------------------------------------------------
// SmartContract
// ---------------------------------------------------------------------------

// SmartContract provides the entry point for the UAV Swarm Digital Twin chaincode.
type SmartContract struct {
	contractapi.Contract
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// txTimestamp returns an ISO-8601 timestamp derived from the transaction's
// deterministic timestamp (not wall-clock time).
func txTimestamp(ctx contractapi.TransactionContextInterface) (string, error) {
	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return "", fmt.Errorf("failed to get transaction timestamp: %w", err)
	}
	return time.Unix(ts.Seconds, int64(ts.Nanos)).UTC().Format(time.RFC3339), nil
}

// putState marshals v to JSON and writes it under key.
func putState(ctx contractapi.TransactionContextInterface, key string, v interface{}) error {
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Errorf("failed to marshal JSON: %w", err)
	}
	return ctx.GetStub().PutState(key, b)
}

// emitEvent sets a chaincode event with a JSON payload.
func emitEvent(ctx contractapi.TransactionContextInterface, name string, payload interface{}) error {
	b, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("failed to marshal event payload: %w", err)
	}
	return ctx.GetStub().SetEvent(name, b)
}

// getUAV reads and unmarshals a UAVDescriptor from the world state.
func getUAV(ctx contractapi.TransactionContextInterface, uavID string) (*UAVDescriptor, error) {
	data, err := ctx.GetStub().GetState(uavID)
	if err != nil {
		return nil, fmt.Errorf("failed to read UAV %s: %w", uavID, err)
	}
	if data == nil {
		return nil, fmt.Errorf("UAV %s does not exist", uavID)
	}
	var uav UAVDescriptor
	if err := json.Unmarshal(data, &uav); err != nil {
		return nil, fmt.Errorf("failed to unmarshal UAV %s: %w", uavID, err)
	}
	return &uav, nil
}

// getHandover reads and unmarshals a HandoverRecord from the world state.
func getHandover(ctx contractapi.TransactionContextInterface, handoverID string) (*HandoverRecord, error) {
	data, err := ctx.GetStub().GetState(handoverID)
	if err != nil {
		return nil, fmt.Errorf("failed to read handover %s: %w", handoverID, err)
	}
	if data == nil {
		return nil, fmt.Errorf("handover %s does not exist", handoverID)
	}
	var h HandoverRecord
	if err := json.Unmarshal(data, &h); err != nil {
		return nil, fmt.Errorf("failed to unmarshal handover %s: %w", handoverID, err)
	}
	return &h, nil
}

// createCompositeKey is a convenience wrapper.
func createCompositeKey(ctx contractapi.TransactionContextInterface, objectType string, attrs []string) (string, error) {
	return ctx.GetStub().CreateCompositeKey(objectType, attrs)
}

// putCompositeKey stores a zero-byte value under a composite key for range queries.
func putCompositeKey(ctx contractapi.TransactionContextInterface, objectType string, attrs []string) error {
	key, err := createCompositeKey(ctx, objectType, attrs)
	if err != nil {
		return fmt.Errorf("failed to create composite key: %w", err)
	}
	return ctx.GetStub().PutState(key, []byte{0x00})
}

// deleteCompositeKey removes a composite key entry.
func deleteCompositeKey(ctx contractapi.TransactionContextInterface, objectType string, attrs []string) error {
	key, err := createCompositeKey(ctx, objectType, attrs)
	if err != nil {
		return fmt.Errorf("failed to create composite key for deletion: %w", err)
	}
	return ctx.GetStub().DelState(key)
}

// =========================================================================
// Family 1: Telemetry & Digital Twin Maintenance
// =========================================================================

// InitLedger seeds the world state with the four UAV descriptors matching the
// Raspberry Pi cluster.
func (s *SmartContract) InitLedger(ctx contractapi.TransactionContextInterface) error {
	ts, err := txTimestamp(ctx)
	if err != nil {
		return err
	}

	uavs := []UAVDescriptor{
		{
			DocType: "uav", UAVID: "UAV-001", Status: StatusActive,
			BatteryLevel: 100, CPUUsage: 15, RAMUsage: 30, StorageUsage: 20, LinkQuality: 95,
			Position:       Position{Latitude: 40.4168, Longitude: -3.7038, Altitude: 50},
			BlockchainRole: RoleOrderer, ServiceRole: ServiceNone, AssignedImage: "",
			LastUpdate: ts, OrgMSP: "OrdererMSP",
		},
		{
			DocType: "uav", UAVID: "UAV-002", Status: StatusActive,
			BatteryLevel: 100, CPUUsage: 20, RAMUsage: 35, StorageUsage: 25, LinkQuality: 90,
			Position:       Position{Latitude: 40.4170, Longitude: -3.7040, Altitude: 50},
			BlockchainRole: RoleEndorser, ServiceRole: ServiceHost, AssignedImage: "swarm-service:v1.0",
			LastUpdate: ts, OrgMSP: "SwarmOrg1MSP",
		},
		{
			DocType: "uav", UAVID: "UAV-003", Status: StatusActive,
			BatteryLevel: 100, CPUUsage: 18, RAMUsage: 32, StorageUsage: 22, LinkQuality: 92,
			Position:       Position{Latitude: 40.4172, Longitude: -3.7042, Altitude: 50},
			BlockchainRole: RoleEndorser, ServiceRole: ServiceStandby, AssignedImage: "",
			LastUpdate: ts, OrgMSP: "SwarmOrg2MSP",
		},
		{
			DocType: "uav", UAVID: "UAV-004", Status: StatusStandby,
			BatteryLevel: 100, CPUUsage: 5, RAMUsage: 10, StorageUsage: 10, LinkQuality: 88,
			Position:       Position{Latitude: 40.4174, Longitude: -3.7044, Altitude: 0},
			BlockchainRole: RoleClient, ServiceRole: ServiceNone, AssignedImage: "",
			LastUpdate: ts, OrgMSP: "SwarmOrg1MSP",
		},
	}

	for _, uav := range uavs {
		if err := putState(ctx, uav.UAVID, uav); err != nil {
			return fmt.Errorf("failed to put UAV %s: %w", uav.UAVID, err)
		}
		// Composite key: uav~status~id for status-based queries.
		if err := putCompositeKey(ctx, "uav~status~id", []string{uav.Status, uav.UAVID}); err != nil {
			return fmt.Errorf("failed to create composite key for UAV %s: %w", uav.UAVID, err)
		}
	}

	return nil
}

// RegisterUAV creates a new UAV descriptor in the world state. The UAV starts
// in STANDBY status with all telemetry at zero.
func (s *SmartContract) RegisterUAV(ctx contractapi.TransactionContextInterface, uavID, orgMSP, blockchainRole string) error {
	if uavID == "" {
		return fmt.Errorf("uavId must not be empty")
	}
	if orgMSP == "" {
		return fmt.Errorf("orgMsp must not be empty")
	}
	if blockchainRole == "" {
		return fmt.Errorf("blockchainRole must not be empty")
	}

	existing, err := ctx.GetStub().GetState(uavID)
	if err != nil {
		return fmt.Errorf("failed to check existence of UAV %s: %w", uavID, err)
	}
	if existing != nil {
		return fmt.Errorf("UAV %s already exists", uavID)
	}

	ts, err := txTimestamp(ctx)
	if err != nil {
		return err
	}

	uav := UAVDescriptor{
		DocType:        "uav",
		UAVID:          uavID,
		Status:         StatusStandby,
		BatteryLevel:   100,
		CPUUsage:       0,
		RAMUsage:       0,
		StorageUsage:   0,
		LinkQuality:    0,
		Position:       Position{},
		BlockchainRole: blockchainRole,
		ServiceRole:    ServiceNone,
		AssignedImage:  "",
		LastUpdate:     ts,
		OrgMSP:         orgMSP,
	}

	if err := putState(ctx, uavID, uav); err != nil {
		return err
	}
	return putCompositeKey(ctx, "uav~status~id", []string{uav.Status, uav.UAVID})
}

// UpdateTelemetry writes the latest sensor readings for a UAV. This is the
// highest-frequency transaction in the network.
func (s *SmartContract) UpdateTelemetry(
	ctx contractapi.TransactionContextInterface,
	uavID string,
	battery, cpu, ram, storage, linkQuality float64,
	lat, lon, alt float64,
) error {
	if uavID == "" {
		return fmt.Errorf("uavId must not be empty")
	}

	uav, err := getUAV(ctx, uavID)
	if err != nil {
		return err
	}

	ts, err := txTimestamp(ctx)
	if err != nil {
		return err
	}

	uav.BatteryLevel = battery
	uav.CPUUsage = cpu
	uav.RAMUsage = ram
	uav.StorageUsage = storage
	uav.LinkQuality = linkQuality
	uav.Position = Position{Latitude: lat, Longitude: lon, Altitude: alt}
	uav.LastUpdate = ts

	return putState(ctx, uavID, uav)
}

// GetUAVState returns the full UAVDescriptor for a single UAV.
func (s *SmartContract) GetUAVState(ctx contractapi.TransactionContextInterface, uavID string) (*UAVDescriptor, error) {
	if uavID == "" {
		return nil, fmt.Errorf("uavId must not be empty")
	}
	return getUAV(ctx, uavID)
}

// GetAllUAVs returns every UAVDescriptor stored in the world state by scanning
// the uav~status~id composite key namespace.
func (s *SmartContract) GetAllUAVs(ctx contractapi.TransactionContextInterface) ([]*UAVDescriptor, error) {
	iter, err := ctx.GetStub().GetStateByPartialCompositeKey("uav~status~id", []string{})
	if err != nil {
		return nil, fmt.Errorf("failed to get UAV iterator: %w", err)
	}
	defer iter.Close()

	var uavs []*UAVDescriptor
	for iter.HasNext() {
		kv, err := iter.Next()
		if err != nil {
			return nil, fmt.Errorf("failed to iterate UAVs: %w", err)
		}

		_, compositeKeyParts, err := ctx.GetStub().SplitCompositeKey(kv.Key)
		if err != nil {
			return nil, fmt.Errorf("failed to split composite key: %w", err)
		}
		if len(compositeKeyParts) < 2 {
			continue
		}
		uavID := compositeKeyParts[1]

		uav, err := getUAV(ctx, uavID)
		if err != nil {
			return nil, err
		}
		uavs = append(uavs, uav)
	}
	return uavs, nil
}

// GetUAVsByStatus returns all UAV descriptors with the given status.
func (s *SmartContract) GetUAVsByStatus(ctx contractapi.TransactionContextInterface, status string) ([]*UAVDescriptor, error) {
	if status == "" {
		return nil, fmt.Errorf("status must not be empty")
	}

	iter, err := ctx.GetStub().GetStateByPartialCompositeKey("uav~status~id", []string{status})
	if err != nil {
		return nil, fmt.Errorf("failed to query UAVs by status %s: %w", status, err)
	}
	defer iter.Close()

	var uavs []*UAVDescriptor
	for iter.HasNext() {
		kv, err := iter.Next()
		if err != nil {
			return nil, fmt.Errorf("failed to iterate UAVs: %w", err)
		}

		_, compositeKeyParts, err := ctx.GetStub().SplitCompositeKey(kv.Key)
		if err != nil {
			return nil, fmt.Errorf("failed to split composite key: %w", err)
		}
		if len(compositeKeyParts) < 2 {
			continue
		}
		uavID := compositeKeyParts[1]

		uav, err := getUAV(ctx, uavID)
		if err != nil {
			return nil, err
		}
		uavs = append(uavs, uav)
	}
	return uavs, nil
}

// CheckDepletionThreshold inspects a UAV's battery level. If the battery is at
// or below the threshold the UAV status is set to DEPLETED and a
// "DepletionDetected" chaincode event is emitted.
func (s *SmartContract) CheckDepletionThreshold(
	ctx contractapi.TransactionContextInterface,
	uavID string,
	batteryThreshold float64,
) (bool, error) {
	if uavID == "" {
		return false, fmt.Errorf("uavId must not be empty")
	}

	uav, err := getUAV(ctx, uavID)
	if err != nil {
		return false, err
	}

	if uav.BatteryLevel > batteryThreshold {
		return false, nil // battery is fine
	}

	// Battery is at or below threshold — mark as DEPLETED.
	oldStatus := uav.Status
	uav.Status = StatusDepleted

	ts, err := txTimestamp(ctx)
	if err != nil {
		return false, err
	}
	uav.LastUpdate = ts

	if err := putState(ctx, uavID, uav); err != nil {
		return false, err
	}

	// Update composite keys: remove old status, add new.
	if err := deleteCompositeKey(ctx, "uav~status~id", []string{oldStatus, uavID}); err != nil {
		return false, err
	}
	if err := putCompositeKey(ctx, "uav~status~id", []string{StatusDepleted, uavID}); err != nil {
		return false, err
	}

	// Emit depletion event.
	eventPayload := map[string]interface{}{
		"uavId":        uavID,
		"batteryLevel": uav.BatteryLevel,
		"threshold":    batteryThreshold,
		"timestamp":    ts,
	}
	if err := emitEvent(ctx, EventDepletionDetected, eventPayload); err != nil {
		return false, fmt.Errorf("failed to emit depletion event: %w", err)
	}

	return true, nil
}

// =========================================================================
// Family 2: Service Management
// =========================================================================

// AssignServiceRole assigns a service role (e.g. SERVICE_HOST) to a UAV,
// records a RoleAssignment, and emits a "RoleAssigned" event.
func (s *SmartContract) AssignServiceRole(
	ctx contractapi.TransactionContextInterface,
	uavID, roleName, serviceImage string,
	lat, lon, alt float64,
) error {
	if uavID == "" || roleName == "" {
		return fmt.Errorf("uavId and roleName must not be empty")
	}

	uav, err := getUAV(ctx, uavID)
	if err != nil {
		return err
	}

	if uav.Status != StatusActive && uav.Status != StatusStandby {
		return fmt.Errorf("UAV %s must be ACTIVE or STANDBY to receive a service role (current: %s)", uavID, uav.Status)
	}

	ts, err := txTimestamp(ctx)
	if err != nil {
		return err
	}

	uav.ServiceRole = roleName
	uav.AssignedImage = serviceImage
	uav.Position = Position{Latitude: lat, Longitude: lon, Altitude: alt}
	uav.LastUpdate = ts
	if uav.Status == StatusStandby {
		// Remove old composite key before status change.
		if err := deleteCompositeKey(ctx, "uav~status~id", []string{StatusStandby, uavID}); err != nil {
			return err
		}
		uav.Status = StatusActive
		if err := putCompositeKey(ctx, "uav~status~id", []string{StatusActive, uavID}); err != nil {
			return err
		}
	}

	if err := putState(ctx, uavID, uav); err != nil {
		return err
	}

	// Create RoleAssignment record.
	assignmentID := fmt.Sprintf("role-%s-%s-%s", uavID, RoleTypeService, ts)
	ra := RoleAssignment{
		DocType:      "role",
		AssignmentID: assignmentID,
		UAVID:        uavID,
		RoleType:     RoleTypeService,
		RoleName:     roleName,
		AssignedAt:   ts,
		Active:       true,
	}
	if err := putState(ctx, assignmentID, ra); err != nil {
		return err
	}
	if err := putCompositeKey(ctx, "role~uavid~type", []string{uavID, RoleTypeService, assignmentID}); err != nil {
		return err
	}

	// Emit event.
	return emitEvent(ctx, EventRoleAssigned, map[string]string{
		"uavId":    uavID,
		"roleType": RoleTypeService,
		"roleName": roleName,
	})
}

// RevokeServiceRole clears the service role from a UAV and deactivates the
// corresponding RoleAssignment.
func (s *SmartContract) RevokeServiceRole(ctx contractapi.TransactionContextInterface, uavID string) error {
	if uavID == "" {
		return fmt.Errorf("uavId must not be empty")
	}

	uav, err := getUAV(ctx, uavID)
	if err != nil {
		return err
	}

	if uav.ServiceRole == ServiceNone {
		return fmt.Errorf("UAV %s has no service role to revoke", uavID)
	}

	ts, err := txTimestamp(ctx)
	if err != nil {
		return err
	}

	oldRole := uav.ServiceRole
	uav.ServiceRole = ServiceNone
	uav.AssignedImage = ""
	uav.LastUpdate = ts

	if err := putState(ctx, uavID, uav); err != nil {
		return err
	}

	// Deactivate matching active RoleAssignment(s).
	if err := revokeActiveServiceRoles(ctx, uavID, ts); err != nil {
		return err
	}

	return emitEvent(ctx, EventRoleRevoked, map[string]string{
		"uavId":    uavID,
		"roleType": RoleTypeService,
		"roleName": oldRole,
	})
}

// revokeActiveServiceRoles finds and deactivates all active SERVICE role
// assignments for a given UAV.
func revokeActiveServiceRoles(ctx contractapi.TransactionContextInterface, uavID, ts string) error {
	iter, err := ctx.GetStub().GetStateByPartialCompositeKey("role~uavid~type", []string{uavID, RoleTypeService})
	if err != nil {
		return fmt.Errorf("failed to query role assignments: %w", err)
	}
	defer iter.Close()

	for iter.HasNext() {
		kv, err := iter.Next()
		if err != nil {
			return fmt.Errorf("failed to iterate role assignments: %w", err)
		}

		_, parts, err := ctx.GetStub().SplitCompositeKey(kv.Key)
		if err != nil {
			return err
		}
		if len(parts) < 3 {
			continue
		}
		assignmentID := parts[2]

		data, err := ctx.GetStub().GetState(assignmentID)
		if err != nil || data == nil {
			continue
		}

		var ra RoleAssignment
		if err := json.Unmarshal(data, &ra); err != nil {
			continue
		}
		if !ra.Active {
			continue
		}

		ra.Active = false
		ra.RevokedAt = ts
		if err := putState(ctx, assignmentID, ra); err != nil {
			return err
		}
	}
	return nil
}

// AssignBlockchainRole updates a UAV's blockchain role and records the assignment.
func (s *SmartContract) AssignBlockchainRole(ctx contractapi.TransactionContextInterface, uavID, roleName string) error {
	if uavID == "" || roleName == "" {
		return fmt.Errorf("uavId and roleName must not be empty")
	}

	uav, err := getUAV(ctx, uavID)
	if err != nil {
		return err
	}

	ts, err := txTimestamp(ctx)
	if err != nil {
		return err
	}

	uav.BlockchainRole = roleName
	uav.LastUpdate = ts
	if err := putState(ctx, uavID, uav); err != nil {
		return err
	}

	assignmentID := fmt.Sprintf("role-%s-%s-%s", uavID, RoleTypeBlockchain, ts)
	ra := RoleAssignment{
		DocType:      "role",
		AssignmentID: assignmentID,
		UAVID:        uavID,
		RoleType:     RoleTypeBlockchain,
		RoleName:     roleName,
		AssignedAt:   ts,
		Active:       true,
	}
	if err := putState(ctx, assignmentID, ra); err != nil {
		return err
	}
	if err := putCompositeKey(ctx, "role~uavid~type", []string{uavID, RoleTypeBlockchain, assignmentID}); err != nil {
		return err
	}

	return emitEvent(ctx, EventRoleAssigned, map[string]string{
		"uavId":    uavID,
		"roleType": RoleTypeBlockchain,
		"roleName": roleName,
	})
}

// GetActiveRoleAssignments returns every RoleAssignment that is currently active.
func (s *SmartContract) GetActiveRoleAssignments(ctx contractapi.TransactionContextInterface) ([]*RoleAssignment, error) {
	iter, err := ctx.GetStub().GetStateByPartialCompositeKey("role~uavid~type", []string{})
	if err != nil {
		return nil, fmt.Errorf("failed to query role assignments: %w", err)
	}
	defer iter.Close()

	var active []*RoleAssignment
	for iter.HasNext() {
		kv, err := iter.Next()
		if err != nil {
			return nil, fmt.Errorf("failed to iterate role assignments: %w", err)
		}

		_, parts, err := ctx.GetStub().SplitCompositeKey(kv.Key)
		if err != nil {
			return nil, err
		}
		if len(parts) < 3 {
			continue
		}
		assignmentID := parts[2]

		data, err := ctx.GetStub().GetState(assignmentID)
		if err != nil || data == nil {
			continue
		}

		var ra RoleAssignment
		if err := json.Unmarshal(data, &ra); err != nil {
			continue
		}
		if ra.Active {
			active = append(active, &ra)
		}
	}
	return active, nil
}

// AssignTargetPosition sets a UAV's target coordinates.
func (s *SmartContract) AssignTargetPosition(ctx contractapi.TransactionContextInterface, uavID string, lat, lon, alt float64) error {
	if uavID == "" {
		return fmt.Errorf("uavId must not be empty")
	}

	uav, err := getUAV(ctx, uavID)
	if err != nil {
		return err
	}

	ts, err := txTimestamp(ctx)
	if err != nil {
		return err
	}

	uav.Position = Position{Latitude: lat, Longitude: lon, Altitude: alt}
	uav.LastUpdate = ts

	return putState(ctx, uavID, uav)
}

// =========================================================================
// Family 3: Handover Coordination
// =========================================================================

// InitiateHandover begins the multi-phase replacement of a depleted UAV.
// The UAV must be in DEPLETED status. A HandoverRecord is created in the
// INITIATED phase and a "HandoverInitiated" event is emitted.
func (s *SmartContract) InitiateHandover(ctx contractapi.TransactionContextInterface, depletedUavID string) (string, error) {
	if depletedUavID == "" {
		return "", fmt.Errorf("depletedUavId must not be empty")
	}

	uav, err := getUAV(ctx, depletedUavID)
	if err != nil {
		return "", err
	}
	if uav.Status != StatusDepleted {
		return "", fmt.Errorf("UAV %s is not DEPLETED (current status: %s)", depletedUavID, uav.Status)
	}

	ts, err := txTimestamp(ctx)
	if err != nil {
		return "", err
	}

	txID := ctx.GetStub().GetTxID()
	handoverID := fmt.Sprintf("handover-%s-%s", depletedUavID, txID[:8])

	h := HandoverRecord{
		DocType:        "handover",
		HandoverID:     handoverID,
		DepletedUAV:    depletedUavID,
		Phase:          PhaseInitiated,
		InitiatedAt:    ts,
		ServiceImage:   uav.AssignedImage,
		TargetPosition: uav.Position,
	}

	if err := putState(ctx, handoverID, h); err != nil {
		return "", err
	}
	if err := putCompositeKey(ctx, "handover~phase~id", []string{PhaseInitiated, handoverID}); err != nil {
		return "", err
	}

	if err := emitEvent(ctx, EventHandoverInitiated, map[string]string{
		"handoverId":  handoverID,
		"depletedUav": depletedUavID,
		"timestamp":   ts,
	}); err != nil {
		return "", err
	}

	return handoverID, nil
}

// SelectReplacement designates a STANDBY UAV as the replacement for a handover.
func (s *SmartContract) SelectReplacement(ctx contractapi.TransactionContextInterface, handoverID, replacementUavID string) error {
	if handoverID == "" || replacementUavID == "" {
		return fmt.Errorf("handoverId and replacementUavId must not be empty")
	}

	h, err := getHandover(ctx, handoverID)
	if err != nil {
		return err
	}
	if h.Phase != PhaseInitiated {
		return fmt.Errorf("handover %s is not in INITIATED phase (current: %s)", handoverID, h.Phase)
	}

	replacement, err := getUAV(ctx, replacementUavID)
	if err != nil {
		return err
	}
	if replacement.Status != StatusStandby {
		return fmt.Errorf("replacement UAV %s must be STANDBY (current: %s)", replacementUavID, replacement.Status)
	}

	// Update composite key: remove INITIATED, add REPLACEMENT_SELECTED.
	if err := deleteCompositeKey(ctx, "handover~phase~id", []string{PhaseInitiated, handoverID}); err != nil {
		return err
	}

	h.ReplacementUAV = replacementUavID
	h.Phase = PhaseReplacementSelected

	if err := putState(ctx, handoverID, h); err != nil {
		return err
	}
	if err := putCompositeKey(ctx, "handover~phase~id", []string{PhaseReplacementSelected, handoverID}); err != nil {
		return err
	}

	return emitEvent(ctx, EventReplacementSelected, map[string]string{
		"handoverId":     handoverID,
		"replacementUav": replacementUavID,
	})
}

// StartMigration transitions the handover to the MIGRATING phase. Both the
// depleted and replacement UAVs are set to REPLACING status.
func (s *SmartContract) StartMigration(ctx contractapi.TransactionContextInterface, handoverID string) error {
	if handoverID == "" {
		return fmt.Errorf("handoverId must not be empty")
	}

	h, err := getHandover(ctx, handoverID)
	if err != nil {
		return err
	}
	if h.Phase != PhaseReplacementSelected {
		return fmt.Errorf("handover %s is not in REPLACEMENT_SELECTED phase (current: %s)", handoverID, h.Phase)
	}

	ts, err := txTimestamp(ctx)
	if err != nil {
		return err
	}

	// Update both UAVs to REPLACING.
	for _, uavID := range []string{h.DepletedUAV, h.ReplacementUAV} {
		uav, err := getUAV(ctx, uavID)
		if err != nil {
			return err
		}
		oldStatus := uav.Status
		uav.Status = StatusReplacing
		uav.LastUpdate = ts
		if err := putState(ctx, uavID, uav); err != nil {
			return err
		}
		if err := deleteCompositeKey(ctx, "uav~status~id", []string{oldStatus, uavID}); err != nil {
			return err
		}
		if err := putCompositeKey(ctx, "uav~status~id", []string{StatusReplacing, uavID}); err != nil {
			return err
		}
	}

	// Update handover phase.
	if err := deleteCompositeKey(ctx, "handover~phase~id", []string{PhaseReplacementSelected, handoverID}); err != nil {
		return err
	}
	h.Phase = PhaseMigrating
	if err := putState(ctx, handoverID, h); err != nil {
		return err
	}
	if err := putCompositeKey(ctx, "handover~phase~id", []string{PhaseMigrating, handoverID}); err != nil {
		return err
	}

	return emitEvent(ctx, EventMigrationStarted, map[string]string{
		"handoverId":     handoverID,
		"depletedUav":    h.DepletedUAV,
		"replacementUav": h.ReplacementUAV,
		"timestamp":      ts,
	})
}

// CompleteMigration finalises the handover. The replacement UAV inherits the
// depleted UAV's service role and image; the depleted UAV goes OFFLINE.
func (s *SmartContract) CompleteMigration(ctx contractapi.TransactionContextInterface, handoverID string) error {
	if handoverID == "" {
		return fmt.Errorf("handoverId must not be empty")
	}

	h, err := getHandover(ctx, handoverID)
	if err != nil {
		return err
	}
	if h.Phase != PhaseMigrating {
		return fmt.Errorf("handover %s is not in MIGRATING phase (current: %s)", handoverID, h.Phase)
	}

	ts, err := txTimestamp(ctx)
	if err != nil {
		return err
	}

	// --- Depleted UAV -> OFFLINE, clear roles ---
	depleted, err := getUAV(ctx, h.DepletedUAV)
	if err != nil {
		return err
	}
	if err := deleteCompositeKey(ctx, "uav~status~id", []string{depleted.Status, depleted.UAVID}); err != nil {
		return err
	}
	depleted.Status = StatusOffline
	depleted.ServiceRole = ServiceNone
	depleted.AssignedImage = ""
	depleted.LastUpdate = ts
	if err := putState(ctx, depleted.UAVID, depleted); err != nil {
		return err
	}
	if err := putCompositeKey(ctx, "uav~status~id", []string{StatusOffline, depleted.UAVID}); err != nil {
		return err
	}
	// Revoke service roles on the depleted UAV.
	if err := revokeActiveServiceRoles(ctx, depleted.UAVID, ts); err != nil {
		return err
	}

	// --- Replacement UAV -> ACTIVE, inherit role ---
	replacement, err := getUAV(ctx, h.ReplacementUAV)
	if err != nil {
		return err
	}
	if err := deleteCompositeKey(ctx, "uav~status~id", []string{replacement.Status, replacement.UAVID}); err != nil {
		return err
	}
	replacement.Status = StatusActive
	replacement.ServiceRole = ServiceHost
	replacement.AssignedImage = h.ServiceImage
	replacement.Position = h.TargetPosition
	replacement.LastUpdate = ts
	if err := putState(ctx, replacement.UAVID, replacement); err != nil {
		return err
	}
	if err := putCompositeKey(ctx, "uav~status~id", []string{StatusActive, replacement.UAVID}); err != nil {
		return err
	}

	// Create a new RoleAssignment for the replacement.
	assignmentID := fmt.Sprintf("role-%s-%s-%s", replacement.UAVID, RoleTypeService, ts)
	ra := RoleAssignment{
		DocType:      "role",
		AssignmentID: assignmentID,
		UAVID:        replacement.UAVID,
		RoleType:     RoleTypeService,
		RoleName:     ServiceHost,
		AssignedAt:   ts,
		Active:       true,
	}
	if err := putState(ctx, assignmentID, ra); err != nil {
		return err
	}
	if err := putCompositeKey(ctx, "role~uavid~type", []string{replacement.UAVID, RoleTypeService, assignmentID}); err != nil {
		return err
	}

	// --- Complete the handover record ---
	if err := deleteCompositeKey(ctx, "handover~phase~id", []string{PhaseMigrating, handoverID}); err != nil {
		return err
	}
	h.Phase = PhaseCompleted
	h.CompletedAt = ts
	if err := putState(ctx, handoverID, h); err != nil {
		return err
	}
	if err := putCompositeKey(ctx, "handover~phase~id", []string{PhaseCompleted, handoverID}); err != nil {
		return err
	}

	return emitEvent(ctx, EventHandoverCompleted, map[string]string{
		"handoverId":     handoverID,
		"depletedUav":    h.DepletedUAV,
		"replacementUav": h.ReplacementUAV,
		"timestamp":      ts,
	})
}

// FailHandover marks a handover as failed and reverts UAV statuses.
func (s *SmartContract) FailHandover(ctx contractapi.TransactionContextInterface, handoverID, reason string) error {
	if handoverID == "" {
		return fmt.Errorf("handoverId must not be empty")
	}

	h, err := getHandover(ctx, handoverID)
	if err != nil {
		return err
	}
	if h.Phase == PhaseCompleted || h.Phase == PhaseFailed {
		return fmt.Errorf("handover %s is already in terminal phase %s", handoverID, h.Phase)
	}

	ts, err := txTimestamp(ctx)
	if err != nil {
		return err
	}

	oldPhase := h.Phase

	// Revert the depleted UAV back to DEPLETED (from REPLACING if applicable).
	depleted, err := getUAV(ctx, h.DepletedUAV)
	if err != nil {
		return err
	}
	if depleted.Status == StatusReplacing {
		if err := deleteCompositeKey(ctx, "uav~status~id", []string{StatusReplacing, depleted.UAVID}); err != nil {
			return err
		}
		depleted.Status = StatusDepleted
		depleted.LastUpdate = ts
		if err := putState(ctx, depleted.UAVID, depleted); err != nil {
			return err
		}
		if err := putCompositeKey(ctx, "uav~status~id", []string{StatusDepleted, depleted.UAVID}); err != nil {
			return err
		}
	}

	// Revert the replacement UAV back to STANDBY (from REPLACING if applicable).
	if h.ReplacementUAV != "" {
		replacement, err := getUAV(ctx, h.ReplacementUAV)
		if err != nil {
			return err
		}
		if replacement.Status == StatusReplacing {
			if err := deleteCompositeKey(ctx, "uav~status~id", []string{StatusReplacing, replacement.UAVID}); err != nil {
				return err
			}
			replacement.Status = StatusStandby
			replacement.LastUpdate = ts
			if err := putState(ctx, replacement.UAVID, replacement); err != nil {
				return err
			}
			if err := putCompositeKey(ctx, "uav~status~id", []string{StatusStandby, replacement.UAVID}); err != nil {
				return err
			}
		}
	}

	// Mark handover as failed.
	if err := deleteCompositeKey(ctx, "handover~phase~id", []string{oldPhase, handoverID}); err != nil {
		return err
	}
	h.Phase = PhaseFailed
	h.CompletedAt = ts
	h.Notes = reason
	if err := putState(ctx, handoverID, h); err != nil {
		return err
	}
	if err := putCompositeKey(ctx, "handover~phase~id", []string{PhaseFailed, handoverID}); err != nil {
		return err
	}

	return emitEvent(ctx, EventHandoverFailed, map[string]string{
		"handoverId": handoverID,
		"reason":     reason,
		"timestamp":  ts,
	})
}

// GetHandoverRecord returns a single HandoverRecord by its ID.
func (s *SmartContract) GetHandoverRecord(ctx contractapi.TransactionContextInterface, handoverID string) (*HandoverRecord, error) {
	if handoverID == "" {
		return nil, fmt.Errorf("handoverId must not be empty")
	}
	return getHandover(ctx, handoverID)
}

// GetActiveHandovers returns all handovers that are not in a terminal phase
// (i.e. not COMPLETED and not FAILED).
func (s *SmartContract) GetActiveHandovers(ctx contractapi.TransactionContextInterface) ([]*HandoverRecord, error) {
	activePhases := []string{PhaseInitiated, PhaseReplacementSelected, PhaseMigrating}
	var results []*HandoverRecord

	for _, phase := range activePhases {
		iter, err := ctx.GetStub().GetStateByPartialCompositeKey("handover~phase~id", []string{phase})
		if err != nil {
			return nil, fmt.Errorf("failed to query handovers in phase %s: %w", phase, err)
		}

		for iter.HasNext() {
			kv, err := iter.Next()
			if err != nil {
				iter.Close()
				return nil, fmt.Errorf("failed to iterate handovers: %w", err)
			}
			_, parts, err := ctx.GetStub().SplitCompositeKey(kv.Key)
			if err != nil {
				iter.Close()
				return nil, err
			}
			if len(parts) < 2 {
				continue
			}
			handoverID := parts[1]
			h, err := getHandover(ctx, handoverID)
			if err != nil {
				iter.Close()
				return nil, err
			}
			results = append(results, h)
		}
		iter.Close()
	}
	return results, nil
}

// GetHandoverHistory returns every handover record (all phases) for audit.
func (s *SmartContract) GetHandoverHistory(ctx contractapi.TransactionContextInterface) ([]*HandoverRecord, error) {
	iter, err := ctx.GetStub().GetStateByPartialCompositeKey("handover~phase~id", []string{})
	if err != nil {
		return nil, fmt.Errorf("failed to query all handovers: %w", err)
	}
	defer iter.Close()

	seen := make(map[string]bool)
	var results []*HandoverRecord

	for iter.HasNext() {
		kv, err := iter.Next()
		if err != nil {
			return nil, fmt.Errorf("failed to iterate handovers: %w", err)
		}
		_, parts, err := ctx.GetStub().SplitCompositeKey(kv.Key)
		if err != nil {
			return nil, err
		}
		if len(parts) < 2 {
			continue
		}
		handoverID := parts[1]
		if seen[handoverID] {
			continue
		}
		seen[handoverID] = true

		h, err := getHandover(ctx, handoverID)
		if err != nil {
			return nil, err
		}
		results = append(results, h)
	}
	return results, nil
}
