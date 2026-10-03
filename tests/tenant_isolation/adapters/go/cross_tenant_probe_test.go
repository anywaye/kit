// Package kitprobe holds THE CROSS-TENANT NEGATIVE SUITE for `identity`.
//
// It is copied in by kit's harness (`tests/tenant_isolation/adapters/go.sh`) and
// is NOT committed to identity. Nothing in identity imports it; it exists only
// inside the throwaway service copy the harness builds, and it is deleted with
// that copy.
//
// # WHAT THIS FILE IS
//
// Two accounts, seeded through identity's own write path — `users.Store.Create`
// and `accounts.Store.Create` / `AddMember` / `CreateInvitation`, which are the
// statements the API's own registration and invitation flows run — and seven
// assertions about what account A can and cannot reach. Each assertion is named
// after the breakage it is the control for, because kit's recipe plants a defect
// in identity's source and asserts that THIS test goes red: a control that could
// be caught by a different test proves the harness can fail and nothing about
// any individual check.
//
// # WHY identity AND WHY THE STORE RATHER THAN THE ROUTER
//
// identity is the fleet's Go service, it is in MVP scope, and it already carries
// the strongest cross-tenant evidence in the fleet. Its scoping is hand-written
// `WHERE account_id = $1` in `internal/accounts/store.go`, which is precisely the
// code a refactor can drop a clause from while the whole suite stays green — its
// own `internal/tenancy` tests assert the SUBSTRATE and say nothing about whether
// these seven predicates are still on the statement.
//
// The store is called directly rather than through `internal/httpapi`. The
// harness's subject is the QUERY LAYER, and the query layer is this file's
// subject: `Store.Members`, `Store.Member`, `Store.SetRole`,
// `Store.RemoveMember` and `Store.RevokePendingInvitation` are the five
// statements a cross-tenant bug would live in, and each of them is what an HTTP
// handler calls. Going through the router would add middleware, a session
// credential and a status-code question without changing what any of these
// statements can see.
//
// # THE CONNECTION IS A SUPERUSER, AND THAT IS DELIBERATE — READ THIS FIRST
//
// `tests/tenancy_test.sh` already proves identity's row-level security: the
// `FORCE`, the `identity_app` login role, the `cafaye.begin_account` seam. This
// file is the OTHER half, and the halves are measured separately on purpose.
//
// Postgres exempts a SUPERUSER from row-level security unconditionally, whatever
// the FORCE says. So this probe's connection cannot be scoped by RLS, which means
// every denial below is caused by identity's own `WHERE account_id = $1` and by
// nothing else. That is what makes the breakages in
// `reports/tenant-adapter-go-01/mutations.sh` mean anything: a predicate removed
// from `Store.Members` is a predicate nothing catches, and this file is the only
// thing in the fleet that would notice.
//
// The cost is stated rather than hidden, and it is real: this suite does NOT prove
// that identity is safe in production, it proves that identity's statements are
// scoped. If RLS is the only thing standing between two accounts in a deployment,
// the answer is `tests/tenancy_test.sh` and the FORCE control, not this file.
//
// # THE ASSERTION SET IS FOUR DENIALS AND TWO ALLOWANCES, NEVER FOUR DENIALS
//
// A probe made only of denials is satisfied by a service that returns nothing to
// anybody. So:
//
//   - TestCrossTenantListOwnRowsVisible is the ALLOWANCE: A must see its own rows.
//     A bind that resolves to nothing at all fails here and passes every denial,
//     which is why it exists as its own test and is asserted in the BASE phase by
//     the recipe, not only after a mutation.
//   - TestTheSubstrateIsNotWhatHoldsThisLine is the ALLOWANCE's other half: the
//     substrate must NOT be scoping this connection. A probe accidentally
//     connected with RLS in the path would have every denial green for a reason
//     that has nothing to do with identity, and that is the vacuous green this
//     repository has a written rule about.
package kitprobe

import (
	"context"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/cafaye/identity/internal/accounts"
	"github.com/cafaye/identity/internal/platform/db"
	"github.com/cafaye/identity/internal/platform/id"
	"github.com/cafaye/identity/internal/users"
)

// ---------------------------------------------------------------------------
// The fixture. Seeded ONCE per `go test` process, in TestMain.
//
// Every case in kit's recipe is a separate `go test` invocation, so the seed runs
// again for each one. Truncating first is what makes that repeatable: without it
// the second run to reach a package would collide on `users_email_key` and the
// recipe would report a red that is an artefact of the recipe.
//
// The truncate is HARNESS SETUP and is the only statement in this file that is
// not identity's own. Every row that the assertions are about is written by
// `users.Store` and `accounts.Store`, so a failure here is identity's query layer
// answering rather than a table this file invented.
// ---------------------------------------------------------------------------

// accountA and accountB are seeded fresh in TestMain rather than being written
// down, so there is no id in this file that a mutation could have to keep in step
// with the schema.
var (
	acctStore *accounts.Store
	userStore *users.Store

	fixtureA tenant
	fixtureB tenant
)

// tenant is one seeded account and everything the assertions need to reach it.
type tenant struct {
	Account      accounts.Account
	Owner        users.User
	Invitation   accounts.Invitation
	MembershipID id.UUID
}

func TestMain(m *testing.M) {
	ctx := context.Background()

	// identity's own rule, and it is the right one here: a database test that
	// SKIPS when the variable is unset has proven nothing, so this fails.
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

// reset empties the four tables the fixture writes to.
func reset(ctx context.Context, pool db.Pool) error {
	_, err := pool.Exec(ctx, `TRUNCATE account_invitations, account_users, accounts, users RESTART IDENTITY CASCADE`)
	return err
}

// seed writes one account through identity's own write path: a user, an account,
// the owner's membership in it, and one pending invitation.
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

// ---------------------------------------------------------------------------
// THE ASSERTIONS. Seven, named after the breakage each one is the control for.
//
// No `t.Parallel()`: the fixture is shared process state, and a suite that could
// interleave a revoke with a member read would report a red nobody planted.
// ---------------------------------------------------------------------------

// TestCrossTenantListOwnRowsVisible is THE ALLOWANCE.
//
// It is the arm every denial-only suite forgets, and it is the one a broken BIND
// needs: the predicate is present and correctly spelled, the value under it is
// not the caller's account, and every statement still returns zero rows. Read as
// a denial that is a pass; read here it is a failure.
//
// kit's recipe asserts on this test's NAME in the BASE phase, before any
// mutation, so a probe whose control only exists after a breakage cannot pass for
// a service that scopes correctly.
func TestCrossTenantListOwnRowsVisible(t *testing.T) {
	rows, err := acctStore.Members(context.Background(), poolOrDie(t.Context()), fixtureA.Account.ID)
	if err != nil {
		t.Fatalf("A listing its own members: %v", err)
	}

	if len(rows) == 0 {
		t.Fatalf("THE ALLOWANCE, and it is the arm a broken bind fails: A's own member "+
			"list is empty. An empty list is a bind that resolves to nothing, not an isolation.")
	}

	for _, m := range rows {
		if m.Account.ID != fixtureA.Account.ID {
			t.Errorf("A's own member list carries account %s, which is not A's", m.Account.ID)
		}
	}
}

// TestCrossTenantListDeniesOtherAccount is breakage 1's control: the predicate is
// GONE from the member list.
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

// TestCrossTenantMemberByIDDeniesOtherAccount is breakage 3's control: IDOR on
// fetch-by-id. A asks for one member by id and gets somebody else's membership.
func TestCrossTenantMemberByIDDeniesOtherAccount(t *testing.T) {
	// A's own account, B's user id. A is in A's account and B's user is in B's,
	// so this pair is a membership that does not exist and must not be found.
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

// TestCrossTenantSetRoleDeniesOtherAccount is breakage 4's control: an unscoped
// update. A changes a role on a membership A does not own.
//
// The role is read back with `Member` on B's OWN account, not asserted from the
// return value: a statement that updated four rows returns one of them and says
// nothing about the other three, so reading the row back is the only assertion
// that can see the damage.
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

// TestCrossTenantRemoveMemberDeniesOtherAccount is breakage 5's control: an
// unscoped delete, on the one operation in this set whose damage is not
// reversible.
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

// TestCrossTenantRevokeInvitationDeniesOtherAccount is breakage 6's control: the
// same unscoped write on a DIFFERENT TABLE, because a boundary held on
// account_users and dropped on account_invitations is a normal outcome rather
// than a contradiction.
func TestCrossTenantRevokeInvitationDeniesOtherAccount(t *testing.T) {
	n, err := acctStore.RevokePendingInvitation(context.Background(), poolOrDie(t.Context()),
		fixtureA.Account.ID, fixtureB.Invitation.ID)

	// NotFound rather than Used/Revoked: B's invitation is pending, and the store
	// itself documents that a row in another account reads as not-found because
	// the lookup is scoped. Asserting the specific sentinel is what separates
	// "refused" from "refused for the wrong reason".
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

// TestTheSubstrateIsNotWhatHoldsThisLine is the second allowance, and it is the
// control for the HARNESS rather than for a breakage.
//
// The probe connects as a superuser, which Postgres exempts from row-level
// security unconditionally. If that exemption ever stopped holding — if a future
// migration granted the role BYPASSRLS differently, or the harness were
// reconfigured to connect as `identity_app` — every denial in this file would go
// green for a reason that has nothing to do with identity, and the six breakages
// would report "stayed green" for a probe that had stopped measuring.
//
// So it is asserted, not assumed: with the account identity SET on the
// transaction, the substrate still shows B's membership. If this test ever goes
// red, the six denials above are measuring the substrate and the recipe's tallies
// mean nothing until it is fixed.
func TestTheSubstrateIsNotWhatHoldsThisLine(t *testing.T) {
	ctx := t.Context()

	tx, err := poolOrDie(ctx).Begin(ctx)
	if err != nil {
		t.Fatalf("beginning a transaction: %v", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// identity's own seam, called by name exactly as internal/tenancy does, so
	// this control proves the substrate is ARMED as well as bypassed. A control
	// that skipped the call would also pass on a probe that never set an identity.
	if _, err := tx.Exec(ctx, `select cafaye.begin_account($1)`, fixtureA.Account.ID); err != nil {
		t.Fatalf("cafaye.begin_account: %v", err)
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

// ---------------------------------------------------------------------------
// The pool handle. Held in a package variable so a helper can reach it without
// threading it through seven signatures, and read through a `mustPool` helper so
// no assertion has to carry a `db.Pool` parameter.
//
// It is a `db.Pool` rather than a `*pgxpool.Pool` so that handing it to a store
// goes through exactly the seam the service's own call sites use: every store in
// identity takes a `db.Querier` and none of them knows what a pool is.
// ---------------------------------------------------------------------------

var pool db.Pool

func poolOrDie(ctx context.Context) db.Pool {
	if pool == nil {
		panic("kitprobe: the pool was never opened; TestMain did not run")
	}
	return pool
}