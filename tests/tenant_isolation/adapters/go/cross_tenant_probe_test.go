package kitprobe

import (
	"context"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/anywaye/identity/internal/accounts"
	"github.com/anywaye/identity/internal/platform/db"
	"github.com/anywaye/identity/internal/platform/id"
	"github.com/anywaye/identity/internal/users"
)


var (
	acctStore *accounts.Store
	userStore *users.Store

	fixtureA tenant
	fixtureB tenant
)

type tenant struct {
	Account      accounts.Account
	Owner        users.User
	Invitation   accounts.Invitation
	MembershipID id.UUID
}

func TestMain(m *testing.M) {
	ctx := context.Background()

	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		fmt.Fprintln(os.Stderr, "kitprobe: TEST_DATABASE_URL is unset. This suite is a database suite;")
		fmt.Fprintln(os.Stderr, "a run with no database has measured nothing, which is not a pass.")
		os.Exit(2)
	}

	opened, err := db.Open(ctx, dsn, db.DefaultOptions())
	if err != nil {
		fmt.Fprintf(os.Stderr, "kitprobe: opening the pool: %v\n", err)
		os.Exit(2)
	}
	defer opened.Close()
	pool = opened

	acctStore = accounts.NewStore(pool)
	userStore = users.NewStore(pool)

	if err := reset(ctx, pool); err != nil {
		fmt.Fprintf(os.Stderr, "kitprobe: clearing the seeded tables: %v\n", err)
		os.Exit(2)
	}

	fixtureA, err = seed(ctx, "kit-probe-a", "kit-probe-a@example.test")
	if err != nil {
		fmt.Fprintf(os.Stderr, "kitprobe: seeding account A: %v\n", err)
		os.Exit(2)
	}
	fixtureB, err = seed(ctx, "kit-probe-b", "kit-probe-b@example.test")
	if err != nil {
		fmt.Fprintf(os.Stderr, "kitprobe: seeding account B: %v\n", err)
		os.Exit(2)
	}

	code := m.Run()
	_ = reset(context.Background(), pool)
	os.Exit(code)
}

func reset(ctx context.Context, pool db.Pool) error {
	_, err := pool.Exec(ctx, `TRUNCATE account_invitations, account_users, accounts, users RESTART IDENTITY CASCADE`)
	return err
}

func seed(ctx context.Context, slug, email string) (tenant, error) {
	var out tenant

	owner, err := userStore.Create(ctx, poolOrDie(ctx), users.CreateParams{
		Email:          email,
		PasswordDigest: "kit-probe-not-a-real-digest",
	})
	if err != nil {
		return out, fmt.Errorf("creating the user: %w", err)
	}
	out.Owner = owner

	account, err := acctStore.Create(ctx, poolOrDie(ctx), accounts.CreateParams{
		Name:     "Kit probe " + slug,
		Slug:     slug,
		Personal: false,
	})
	if err != nil {
		return out, fmt.Errorf("creating the account: %w", err)
	}
	out.Account = account

	membership, err := acctStore.AddMember(ctx, poolOrDie(ctx), accounts.Membership{
		AccountID: account.ID,
		UserID:    owner.ID,
		Role:      accounts.RoleOwner,
	})
	if err != nil {
		return out, fmt.Errorf("adding the owner membership: %w", err)
	}
	out.MembershipID = membership.UserID

	_, digest, err := accounts.NewToken()
	if err != nil {
		return out, fmt.Errorf("minting an invitation token: %w", err)
	}

	invitation, err := acctStore.CreateInvitation(ctx, poolOrDie(ctx), accounts.NewInvitation{
		AccountID:   account.ID,
		Email:       "invitee-" + email,
		Role:        accounts.RoleMember,
		TokenDigest: digest,
		ExpiresAt:   time.Now().Add(accounts.InvitationTTL),
		InvitedBy:   owner.ID,
	})
	if err != nil {
		return out, fmt.Errorf("creating the invitation: %w", err)
	}
	out.Invitation = invitation

	return out, nil
}


func TestCrossTenantListOwnRowsVisible(t *testing.T) {
	rows, err := acctStore.Members(context.Background(), poolOrDie(t.Context()), fixtureA.Account.ID)
	if err != nil {
		t.Fatalf("A listing its own members: %v", err)
	}

	if len(rows) == 0 {
		t.Fatalf("THE ALLOWANCE, and it is the arm a broken bind fails: A's own member " +
			"list is empty. An empty list is a bind that resolves to nothing, not an isolation.")
	}

	for _, m := range rows {
		if m.Account.ID != fixtureA.Account.ID {
			t.Errorf("A's own member list carries account %s, which is not A's", m.Account.ID)
		}
	}
}

func TestCrossTenantListDeniesOtherAccount(t *testing.T) {
	rows, err := acctStore.Members(context.Background(), poolOrDie(t.Context()), fixtureA.Account.ID)
	if err != nil {
		t.Fatalf("A listing its own members: %v", err)
	}

	for _, m := range rows {
		if m.Account.ID == fixtureB.Account.ID {
			t.Fatalf("A's member list carries B's account %s: the list query's account "+
				"predicate is not doing anything", fixtureB.Account.ID)
		}
		if m.UserID == fixtureB.Owner.ID {
			t.Fatalf("A's member list carries B's member %s: the list query's account "+
				"predicate is not doing anything", fixtureB.Owner.ID)
		}
	}
}

func TestCrossTenantMemberByIDDeniesOtherAccount(t *testing.T) {
	m, err := acctStore.Member(context.Background(), poolOrDie(t.Context()),
		fixtureA.Account.ID, fixtureB.Owner.ID)

	if !errors.Is(err, accounts.ErrNotAMember) {
		if err == nil {
			t.Fatalf("A fetched B's membership (account %s, user %s) by id: the "+
				"membership lookup is not scoped to the caller's account",
				m.AccountID, m.UserID)
		}
		t.Fatalf("A fetching B's membership by id: got %v, want ErrNotAMember", err)
	}
}

func TestCrossTenantSetRoleDeniesOtherAccount(t *testing.T) {
	_, err := acctStore.SetRole(context.Background(), poolOrDie(t.Context()),
		fixtureA.Account.ID, fixtureB.Owner.ID, accounts.RoleMember)

	if !errors.Is(err, accounts.ErrNotAMember) {
		t.Fatalf("A changing a role on B's membership: got %v, want ErrNotAMember. "+
			"The UPDATE either reached B's row or reported something else entirely.", err)
	}

	after, err := acctStore.Member(context.Background(), poolOrDie(t.Context()),
		fixtureB.Account.ID, fixtureB.Owner.ID)
	if err != nil {
		t.Fatalf("reading B's membership back: %v", err)
	}
	if after.Role != accounts.RoleOwner {
		t.Fatalf("B's membership role is %q, was %q: A's UPDATE reached B's row",
			after.Role, accounts.RoleOwner)
	}
}

func TestCrossTenantRemoveMemberDeniesOtherAccount(t *testing.T) {
	err := acctStore.RemoveMember(context.Background(), poolOrDie(t.Context()),
		fixtureA.Account.ID, fixtureB.Owner.ID)

	if !errors.Is(err, accounts.ErrNotAMember) {
		t.Fatalf("A removing B from an account: got %v, want ErrNotAMember", err)
	}

	if _, err := acctStore.Member(context.Background(), poolOrDie(t.Context()),
		fixtureB.Account.ID, fixtureB.Owner.ID); err != nil {
		t.Fatalf("B's membership is gone: A's DELETE reached it (%v)", err)
	}
}

func TestCrossTenantRevokeInvitationDeniesOtherAccount(t *testing.T) {
	n, err := acctStore.RevokePendingInvitation(context.Background(), poolOrDie(t.Context()),
		fixtureA.Account.ID, fixtureB.Invitation.ID)

	if !errors.Is(err, accounts.ErrInvitationNotFound) {
		t.Fatalf("A revoking B's invitation: revoked %d, got %v; want 0 and ErrInvitationNotFound",
			n, err)
	}

	after, err := acctStore.InvitationByToken(context.Background(), poolOrDie(t.Context()),
		fixtureB.Invitation.TokenDigest)
	if err != nil {
		t.Fatalf("reading B's invitation back by token: %v", err)
	}
	if after.RevokedAt != nil {
		t.Fatalf("B's invitation was revoked by A: revoked_at is %v", after.RevokedAt)
	}
}

func TestTheSubstrateIsNotWhatHoldsThisLine(t *testing.T) {
	ctx := t.Context()

	tx, err := poolOrDie(ctx).Begin(ctx)
	if err != nil {
		t.Fatalf("beginning a transaction: %v", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx, `select anywaye.begin_account($1)`, fixtureA.Account.ID); err != nil {
		t.Fatalf("anywaye.begin_account: %v", err)
	}

	var visible int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM account_users`).Scan(&visible); err != nil {
		t.Fatalf("counting account_users under the account identity: %v", err)
	}

	if visible < 2 {
		t.Fatalf("THE SUBSTRATE IS SCOPING THIS CONNECTION: with the identity set to A, "+
			"account_users holds %d row(s) and B's membership is invisible. Every denial in "+
			"this file is then being satisfied by row-level security rather than by "+
			"identity's own WHERE clauses, and the six breakages prove nothing.", visible)
	}
}


var pool db.Pool

func poolOrDie(ctx context.Context) db.Pool {
	if pool == nil {
		panic("kitprobe: the pool was never opened; TestMain did not run")
	}
	return pool
}
