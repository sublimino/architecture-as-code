// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"strconv"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// ErrUnrecognisedEnvelope is returned for a JSON object that is neither a
// CloudTrail Records[] file nor a GuardDuty finding. The collector stores it as a
// projection_failure, so an unexpected object in the bucket is a visible record
// rather than a silent zero.
var ErrUnrecognisedEnvelope = errors.New("awslogs: unrecognised envelope: neither a CloudTrail Records[] file nor an EventBridge GuardDuty finding")

// envelopeProbe reads only the two fields that decide which projection a JSON
// object belongs to.
type envelopeProbe struct {
	DetailType string          `json:"detail-type"`
	Records    json.RawMessage `json:"Records"`
}

// guardDutyEnvelope is the allowlist of fields ProjectGuardDuty reads from an
// EventBridge GuardDuty finding. title, description, service and every resource
// detail other than the network interface id are deliberately absent: what is not
// decoded cannot leak (accessKeyDetails carries an access key id and a principal
// userName).
type guardDutyEnvelope struct {
	Source  string `json:"source"`
	Account string `json:"account"`
	Time    string `json:"time"`
	Region  string `json:"region"`
	Detail  struct {
		AccountID string   `json:"accountId"`
		Region    string   `json:"region"`
		Type      string   `json:"type"`
		Severity  *float64 `json:"severity"`
		Resource  struct {
			ResourceType    string `json:"resourceType"`
			InstanceDetails struct {
				NetworkInterfaces []struct {
					NetworkInterfaceID string `json:"networkInterfaceId"`
				} `json:"networkInterfaces"`
			} `json:"instanceDetails"`
		} `json:"resource"`
	} `json:"detail"`
}

// eniID is the shape of an EC2 network interface id. It is the only resource
// identifier a finding may contribute as resource_name: it names no principal and
// carries no ARN.
var eniID = regexp.MustCompile(`^eni-[0-9a-f]{8,17}$`)

// ProjectGuardDuty projects one EventBridge GuardDuty finding to one observation
// under the GuardDuty column of the §2.3 contract.
func (p Projector) ProjectGuardDuty(body []byte, origin Origin) ([]model.Observation, error) {
	var env guardDutyEnvelope
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("awslogs: decoding GuardDuty envelope %s: %w", origin.Key, err)
	}
	ts, err := time.Parse(time.RFC3339, env.Time)
	if err != nil {
		return nil, fmt.Errorf("awslogs: %s: parsing GuardDuty envelope time %q: %w", origin.Key, env.Time, err)
	}
	d := env.Detail
	if d.Type == "" {
		return nil, fmt.Errorf("awslogs: %s: GuardDuty finding has no detail.type", origin.Key)
	}
	if d.Severity == nil || math.IsNaN(*d.Severity) || *d.Severity < 0 || *d.Severity > 10 {
		return nil, fmt.Errorf("awslogs: %s: GuardDuty finding has no usable detail.severity", origin.Key)
	}
	if d.Resource.ResourceType == "" {
		return nil, fmt.Errorf("awslogs: %s: GuardDuty finding has no detail.resource.resourceType", origin.Key)
	}

	account := firstNonEmpty(d.AccountID, env.Account)
	region := firstNonEmpty(d.Region, env.Region, p.Region)
	labels := map[string]string{
		LabelTenantID:     p.TenantID,
		LabelProvider:     ProviderAWS,
		LabelAWSAccountID: account,
		LabelAWSRegion:    region,
		LabelEventSource:  env.Source,
		LabelEventName:    d.Type,
		LabelSeverity:     strconv.FormatInt(int64(math.Floor(*d.Severity)), 10),
		LabelResourceType: d.Resource.ResourceType,
	}
	if nics := d.Resource.InstanceDetails.NetworkInterfaces; len(nics) > 0 && eniID.MatchString(nics[0].NetworkInterfaceID) {
		labels[LabelResourceName] = nics[0].NetworkInterfaceID
	}

	ref := origin.Ref(0)
	return []model.Observation{{
		ID:         derivedObservationID(ref),
		Timestamp:  ts.UTC(),
		Layer:      model.LayerCloudControlPlane,
		Fidelity:   model.FidelityStrong,
		Source:     SourceGuardDuty,
		Confidence: 0.9,
		// No ActorHint: the finding names a userName at most, never an ARN, and a
		// fabricated ARN would pseudonymise to an identity that matches nothing.
		RawEvidenceRef: ref,
		Labels:         labels,
		Description:    guardDutyDescription(labels),
	}}, nil
}

// guardDutyDescription names the finding type and the resource type only. The
// title, the resource identifier and every principal field stay in the bucket.
func guardDutyDescription(labels map[string]string) string {
	return oneLine("guardduty " + labels[LabelEventName] + " on " + labels[LabelResourceType])
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}
