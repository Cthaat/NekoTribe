package server

import (
	"context"
	"database/sql"
	"testing"
)

func TestNotificationStorageHonorsRecipientAndPreferences(t *testing.T) {
	for _, tc := range []struct {
		name                       string
		user, actor, push, enabled int64
		stored, canPush            bool
	}{
		{"self", 42, 42, 1, 1, false, false},
		{"invalid recipient", 0, 7, 1, 1, false, false},
		{"type disabled", 42, 7, 1, 0, false, false},
		{"push disabled still stored", 42, 7, 0, 1, true, false},
		{"enabled", 42, 7, 1, 1, true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := &alertState{push: tc.push, enabled: tc.enabled}
			db := sql.OpenDB(alertConnector{state})
			defer db.Close()
			actor := tc.actor
			resourceType := "post"
			resourceID := int64(9)
			got, err := (OracleSessions{db}).storeNotification(context.Background(), notificationInput{UserID: tc.user, ActorID: &actor, Type: "like", Title: "test", Message: "test", ResourceType: &resourceType, ResourceID: &resourceID, Priority: "normal", MetadataJSON: `{"event":"post_like"}`})
			if err != nil || (got != nil) != tc.stored || (state.commits == 1) != tc.stored {
				t.Fatalf("result=%+v commits=%d err=%v", got, state.commits, err)
			}
			if got != nil {
				if got.ID != 44 || got.PushEnabled != tc.canPush {
					t.Fatal(got)
				}
				want := map[string]any{"user_id": tc.user, "actor_id": tc.actor, "resource_id": resourceID, "resource_type": resourceType, "type": "like"}
				for _, a := range state.args {
					if v, ok := want[a.Name]; ok {
						if a.Value != v {
							t.Fatalf("bad binding %s: %v", a.Name, a.Value)
						}
						delete(want, a.Name)
					}
				}
				if len(want) > 0 {
					t.Fatal("missing bind", want)
				}
			}
		})
	}
}
func TestNotificationStoragePropagatesWriteFailureWithoutPrivateDetails(t *testing.T) {
	state := &alertState{push: 1, enabled: 1}
	state.fail = "execute"
	db := sql.OpenDB(alertConnector{state})
	defer db.Close()
	actor := int64(7)
	got, err := (OracleSessions{db}).storeNotification(context.Background(), notificationInput{UserID: 42, ActorID: &actor, Type: "like"})
	if got != nil || err != errSessionStore || state.commits != 0 {
		t.Fatal(got, err, state.commits)
	}
}

func TestNotificationStorageIgnoresMissingOrInactiveRecipient(t *testing.T) {
	state := &alertState{inactive: true, push: 1, enabled: 1}
	db := sql.OpenDB(alertConnector{state})
	defer db.Close()
	actor := int64(7)
	got, err := (OracleSessions{db}).storeNotification(context.Background(), notificationInput{UserID: 42, ActorID: &actor, Type: "like"})
	if got != nil || err != nil || state.commits != 0 {
		t.Fatal(got, err, state.commits)
	}
}
