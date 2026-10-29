//go:build tier_db

package dbtest

import (
	"database/sql"
	"os"
	"testing"
)

func TestTierDBPoolRoundTrips(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		if os.Getenv("REQUIRED_DB") == "1" {
			t.Fatal("REQUIRED_DB=1 and TEST_DATABASE_URL is unset: the db tier cannot run. " +
				"Start the database, or unset REQUIRED_DB to skip this tier on purpose.")
		}
		t.Skip("TEST_DATABASE_URL unset: db tier not requested on this run")
	}

	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer func() { _ = db.Close() }()

	if err := db.Ping(); err != nil {
		t.Fatalf("ping: %v", err)
	}
	var one int
	if err := db.QueryRow("SELECT 1").Scan(&one); err != nil {
		t.Fatalf("SELECT 1: %v", err)
	}
	if one != 1 {
		t.Fatalf("SELECT 1 = %d, want 1", one)
	}
}
