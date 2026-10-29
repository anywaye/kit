
import os

import pytest


@pytest.mark.tier_db
def test_tier_db_pool_round_trips():
    dsn = os.environ.get("TEST_DATABASE_URL")
    if not dsn:
        if os.environ.get("REQUIRED_DB") == "1":
            pytest.fail(
                "REQUIRED_DB=1 and TEST_DATABASE_URL is unset: the db tier cannot run. "
                "Start the database, or unset REQUIRED_DB to skip this tier on purpose."
            )
        pytest.skip("TEST_DATABASE_URL unset: db tier not requested on this run")

    assert dsn.startswith("postgres"), dsn

    conn = _connect(dsn)
    try:
        assert conn.execute("SELECT 1").fetchone() == (1,)
    finally:
        conn.close()


def _connect(dsn):
    raise NotImplementedError("substitute your own driver; the tier contract is above")
