
TIER = "db"


def pytest_configure(config):
    """Register the tier markers.

    `config.addinivalue_line` is the documented registration path; editing
    `markers` in pyproject.toml instead is equivalent and this file is what a
    repo copies, so both work and neither is required to be the other.
    """
    config.addinivalue_line(
        "markers",
        f"tier_{TIER}: needs a real {TIER}; runs when REQUIRED_{TIER.upper()}=1",
    )
