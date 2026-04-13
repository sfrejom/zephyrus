// SPDX-License-Identifier: Apache-2.0

package chaincode_test

import (
	"encoding/json"
	"fmt"
	"testing"

	"github.com/hyperledger/fabric-chaincode-go/shim"
	"github.com/hyperledger/fabric-contract-api-go/contractapi"
	"github.com/hyperledger/fabric-protos-go/ledger/queryresult"
	cc "github.com/spilab/swarm-management/chaincode"
	"github.com/stretchr/testify/require"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// ---------------------------------------------------------------------------
// Minimal stub / context mocks
// ---------------------------------------------------------------------------

// fakeStub implements a minimal subset of shim.ChaincodeStubInterface used by
// the smart contract. In a real project one would use one of the community
// mock generators (e.g. counterfeiter); this hand-rolled version is sufficient
// for unit-level smoke tests.
type fakeStub struct {
	shim.ChaincodeStubInterface

	state  map[string][]byte
	events map[string][]byte
	txID   string
}

func newFakeStub() *fakeStub {
	return &fakeStub{
		state:  make(map[string][]byte),
		events: make(map[string][]byte),
		txID:   "tx-test-0001abcd",
	}
}

func (f *fakeStub) GetState(key string) ([]byte, error) {
	return f.state[key], nil
}

func (f *fakeStub) PutState(key string, value []byte) error {
	f.state[key] = value
	return nil
}

func (f *fakeStub) DelState(key string) error {
	delete(f.state, key)
	return nil
}

func (f *fakeStub) GetTxID() string {
	return f.txID
}

func (f *fakeStub) GetTxTimestamp() (*timestamppb.Timestamp, error) {
	return &timestamppb.Timestamp{Seconds: 1710000000, Nanos: 0}, nil
}

func (f *fakeStub) SetEvent(name string, payload []byte) error {
	f.events[name] = payload
	return nil
}

func (f *fakeStub) CreateCompositeKey(objectType string, attrs []string) (string, error) {
	key := objectType
	for _, a := range attrs {
		key += "\x00" + a
	}
	key += "\x00"
	return key, nil
}

func (f *fakeStub) SplitCompositeKey(compositeKey string) (string, []string, error) {
	var parts []string
	current := ""
	objectType := ""
	first := true
	for _, ch := range compositeKey {
		if ch == 0x00 {
			if first {
				objectType = current
				first = false
			} else if current != "" {
				parts = append(parts, current)
			}
			current = ""
		} else {
			current += string(ch)
		}
	}
	if current != "" {
		parts = append(parts, current)
	}
	return objectType, parts, nil
}

func (f *fakeStub) GetStateByPartialCompositeKey(objectType string, attrs []string) (shim.StateQueryIteratorInterface, error) {
	prefix := objectType
	for _, a := range attrs {
		prefix += "\x00" + a
	}

	var keys []string
	var values [][]byte
	for k, v := range f.state {
		if len(k) >= len(prefix) && k[:len(prefix)] == prefix {
			keys = append(keys, k)
			values = append(values, v)
		}
	}
	return &fakeIterator{keys: keys, values: values}, nil
}

// fakeIterator satisfies shim.StateQueryIteratorInterface.
type fakeIterator struct {
	keys    []string
	values  [][]byte
	current int
}

func (it *fakeIterator) HasNext() bool {
	return it.current < len(it.keys)
}

func (it *fakeIterator) Next() (*queryresult.KV, error) {
	if !it.HasNext() {
		return nil, fmt.Errorf("no more results")
	}
	kv := &queryresult.KV{
		Key:   it.keys[it.current],
		Value: it.values[it.current],
	}
	it.current++
	return kv, nil
}

func (it *fakeIterator) Close() error {
	return nil
}

// fakeContext satisfies contractapi.TransactionContextInterface by delegating
// to our fakeStub.
type fakeContext struct {
	contractapi.TransactionContext
	stub *fakeStub
}

func (f *fakeContext) GetStub() shim.ChaincodeStubInterface {
	return f.stub
}

func newTestContext() *fakeContext {
	return &fakeContext{stub: newFakeStub()}
}

// ---------------------------------------------------------------------------
// Tests — Family 1: Telemetry & Digital Twin Maintenance
// ---------------------------------------------------------------------------

func TestInitLedger(t *testing.T) {
	ctx := newTestContext()
	contract := new(cc.SmartContract)

	err := contract.InitLedger(ctx)
	require.NoError(t, err, "InitLedger should succeed")

	data, err := ctx.stub.GetState("UAV-001")
	require.NoError(t, err)
	require.NotNil(t, data)

	var uav cc.UAVDescriptor
	err = json.Unmarshal(data, &uav)
	require.NoError(t, err)
	require.Equal(t, "UAV-001", uav.UAVID)
	require.Equal(t, "ORDERER", uav.BlockchainRole)
	require.Equal(t, "OrdererMSP", uav.OrgMSP)

	data, err = ctx.stub.GetState("UAV-004")
	require.NoError(t, err)
	require.NotNil(t, data)

	err = json.Unmarshal(data, &uav)
	require.NoError(t, err)
	require.Equal(t, "STANDBY", uav.Status)
	require.Equal(t, "CLIENT", uav.BlockchainRole)
}

func TestRegisterUAV(t *testing.T) {
	ctx := newTestContext()
	contract := new(cc.SmartContract)

	err := contract.RegisterUAV(ctx, "UAV-005", "SwarmOrg1MSP", "ENDORSER")
	require.NoError(t, err)

	uav, err := contract.GetUAVState(ctx, "UAV-005")
	require.NoError(t, err)
	require.Equal(t, "UAV-005", uav.UAVID)
	require.Equal(t, "STANDBY", uav.Status)
	require.Equal(t, float64(100), uav.BatteryLevel)

	// Duplicate registration should fail.
	err = contract.RegisterUAV(ctx, "UAV-005", "SwarmOrg1MSP", "ENDORSER")
	require.Error(t, err)
	require.Contains(t, err.Error(), "already exists")
}

func TestRegisterUAV_Validation(t *testing.T) {
	ctx := newTestContext()
	contract := new(cc.SmartContract)

	err := contract.RegisterUAV(ctx, "", "SwarmOrg1MSP", "ENDORSER")
	require.Error(t, err, "empty uavId should be rejected")

	err = contract.RegisterUAV(ctx, "UAV-X", "", "ENDORSER")
	require.Error(t, err, "empty orgMsp should be rejected")

	err = contract.RegisterUAV(ctx, "UAV-X", "SwarmOrg1MSP", "")
	require.Error(t, err, "empty blockchainRole should be rejected")
}

func TestUpdateTelemetry(t *testing.T) {
	ctx := newTestContext()
	contract := new(cc.SmartContract)

	require.NoError(t, contract.InitLedger(ctx))

	err := contract.UpdateTelemetry(ctx, "UAV-002", 42.5, 60, 55, 30, 80, 41.0, -4.0, 100)
	require.NoError(t, err)

	uav, err := contract.GetUAVState(ctx, "UAV-002")
	require.NoError(t, err)
	require.InDelta(t, 42.5, uav.BatteryLevel, 0.01)
	require.InDelta(t, 60.0, uav.CPUUsage, 0.01)
	require.InDelta(t, 100.0, uav.Position.Altitude, 0.01)
}

func TestUpdateTelemetry_NonExistentUAV(t *testing.T) {
	ctx := newTestContext()
	contract := new(cc.SmartContract)

	err := contract.UpdateTelemetry(ctx, "UAV-GHOST", 50, 50, 50, 50, 50, 0, 0, 0)
	require.Error(t, err)
	require.Contains(t, err.Error(), "does not exist")
}

func TestCheckDepletionThreshold(t *testing.T) {
	ctx := newTestContext()
	contract := new(cc.SmartContract)

	require.NoError(t, contract.InitLedger(ctx))

	// Battery at 100 — should NOT trigger depletion at threshold 20.
	depleted, err := contract.CheckDepletionThreshold(ctx, "UAV-002", 20)
	require.NoError(t, err)
	require.False(t, depleted)

	// Lower battery, then check again.
	require.NoError(t, contract.UpdateTelemetry(ctx, "UAV-002", 15, 60, 55, 30, 80, 41, -4, 100))

	depleted, err = contract.CheckDepletionThreshold(ctx, "UAV-002", 20)
	require.NoError(t, err)
	require.True(t, depleted)

	// Verify status changed to DEPLETED.
	uav, err := contract.GetUAVState(ctx, "UAV-002")
	require.NoError(t, err)
	require.Equal(t, "DEPLETED", uav.Status)

	// Verify event was emitted.
	require.Contains(t, ctx.stub.events, "DepletionDetected")
}

// ---------------------------------------------------------------------------
// Tests — Family 2: Service Management
// ---------------------------------------------------------------------------

func TestAssignAndRevokeServiceRole(t *testing.T) {
	ctx := newTestContext()
	contract := new(cc.SmartContract)

	require.NoError(t, contract.InitLedger(ctx))

	// UAV-004 is STANDBY — assign it a service role.
	err := contract.AssignServiceRole(ctx, "UAV-004", "SERVICE_HOST", "monitor:v2", 40.42, -3.71, 60)
	require.NoError(t, err)

	uav, err := contract.GetUAVState(ctx, "UAV-004")
	require.NoError(t, err)
	require.Equal(t, "SERVICE_HOST", uav.ServiceRole)
	require.Equal(t, "ACTIVE", uav.Status) // promoted from STANDBY
	require.Equal(t, "monitor:v2", uav.AssignedImage)

	// Revoke.
	err = contract.RevokeServiceRole(ctx, "UAV-004")
	require.NoError(t, err)

	uav, err = contract.GetUAVState(ctx, "UAV-004")
	require.NoError(t, err)
	require.Equal(t, "NONE", uav.ServiceRole)
	require.Equal(t, "", uav.AssignedImage)
}

func TestAssignBlockchainRole(t *testing.T) {
	ctx := newTestContext()
	contract := new(cc.SmartContract)

	require.NoError(t, contract.InitLedger(ctx))

	err := contract.AssignBlockchainRole(ctx, "UAV-003", "COMMITTER")
	require.NoError(t, err)

	uav, err := contract.GetUAVState(ctx, "UAV-003")
	require.NoError(t, err)
	require.Equal(t, "COMMITTER", uav.BlockchainRole)
}

// ---------------------------------------------------------------------------
// Tests — Family 3: Handover Coordination
// ---------------------------------------------------------------------------

func TestFullHandoverLifecycle(t *testing.T) {
	ctx := newTestContext()
	contract := new(cc.SmartContract)

	require.NoError(t, contract.InitLedger(ctx))

	// Deplete UAV-002.
	require.NoError(t, contract.UpdateTelemetry(ctx, "UAV-002", 10, 60, 55, 30, 80, 41, -4, 100))
	depleted, err := contract.CheckDepletionThreshold(ctx, "UAV-002", 20)
	require.NoError(t, err)
	require.True(t, depleted)

	// Initiate handover.
	handoverID, err := contract.InitiateHandover(ctx, "UAV-002")
	require.NoError(t, err)
	require.NotEmpty(t, handoverID)

	h, err := contract.GetHandoverRecord(ctx, handoverID)
	require.NoError(t, err)
	require.Equal(t, "INITIATED", h.Phase)

	// Select replacement (UAV-004 is STANDBY).
	err = contract.SelectReplacement(ctx, handoverID, "UAV-004")
	require.NoError(t, err)

	h, err = contract.GetHandoverRecord(ctx, handoverID)
	require.NoError(t, err)
	require.Equal(t, "REPLACEMENT_SELECTED", h.Phase)
	require.Equal(t, "UAV-004", h.ReplacementUAV)

	// Start migration.
	err = contract.StartMigration(ctx, handoverID)
	require.NoError(t, err)

	uav2, _ := contract.GetUAVState(ctx, "UAV-002")
	uav4, _ := contract.GetUAVState(ctx, "UAV-004")
	require.Equal(t, "REPLACING", uav2.Status)
	require.Equal(t, "REPLACING", uav4.Status)

	// Complete migration.
	err = contract.CompleteMigration(ctx, handoverID)
	require.NoError(t, err)

	uav2, _ = contract.GetUAVState(ctx, "UAV-002")
	uav4, _ = contract.GetUAVState(ctx, "UAV-004")
	require.Equal(t, "OFFLINE", uav2.Status)
	require.Equal(t, "ACTIVE", uav4.Status)
	require.Equal(t, "SERVICE_HOST", uav4.ServiceRole)

	h, _ = contract.GetHandoverRecord(ctx, handoverID)
	require.Equal(t, "COMPLETED", h.Phase)
	require.NotEmpty(t, h.CompletedAt)
}

func TestInitiateHandover_NotDepleted(t *testing.T) {
	ctx := newTestContext()
	contract := new(cc.SmartContract)

	require.NoError(t, contract.InitLedger(ctx))

	// UAV-001 is ACTIVE, not DEPLETED — should fail.
	_, err := contract.InitiateHandover(ctx, "UAV-001")
	require.Error(t, err)
	require.Contains(t, err.Error(), "not DEPLETED")
}

func TestFailHandover(t *testing.T) {
	ctx := newTestContext()
	contract := new(cc.SmartContract)

	require.NoError(t, contract.InitLedger(ctx))

	// Deplete and start handover.
	require.NoError(t, contract.UpdateTelemetry(ctx, "UAV-002", 10, 60, 55, 30, 80, 41, -4, 100))
	_, _ = contract.CheckDepletionThreshold(ctx, "UAV-002", 20)

	handoverID, err := contract.InitiateHandover(ctx, "UAV-002")
	require.NoError(t, err)

	require.NoError(t, contract.SelectReplacement(ctx, handoverID, "UAV-004"))
	require.NoError(t, contract.StartMigration(ctx, handoverID))

	// Fail the handover.
	err = contract.FailHandover(ctx, handoverID, "network timeout during image transfer")
	require.NoError(t, err)

	// Verify revert.
	uav2, _ := contract.GetUAVState(ctx, "UAV-002")
	uav4, _ := contract.GetUAVState(ctx, "UAV-004")
	require.Equal(t, "DEPLETED", uav2.Status)
	require.Equal(t, "STANDBY", uav4.Status)

	h, _ := contract.GetHandoverRecord(ctx, handoverID)
	require.Equal(t, "FAILED", h.Phase)
	require.Contains(t, h.Notes, "network timeout")
}

func TestSelectReplacement_NotStandby(t *testing.T) {
	ctx := newTestContext()
	contract := new(cc.SmartContract)

	require.NoError(t, contract.InitLedger(ctx))

	// Deplete UAV-002 and initiate handover.
	require.NoError(t, contract.UpdateTelemetry(ctx, "UAV-002", 10, 60, 55, 30, 80, 41, -4, 100))
	_, _ = contract.CheckDepletionThreshold(ctx, "UAV-002", 20)
	handoverID, _ := contract.InitiateHandover(ctx, "UAV-002")

	// Try to select UAV-001 (ACTIVE, not STANDBY) — should fail.
	err := contract.SelectReplacement(ctx, handoverID, "UAV-001")
	require.Error(t, err)
	require.Contains(t, err.Error(), "must be STANDBY")
}
