import os
import tempfile

import pytest

# Point the app at a throwaway SQLite file instead of Postgres, *before* importing
# app.main — database.py reads DATABASE_URL at import time to build its engine.
_db_fd, _db_path = tempfile.mkstemp(suffix=".db")
os.environ["DATABASE_URL"] = f"sqlite:///{_db_path}"

from fastapi.testclient import TestClient  # noqa: E402
from app.main import app  # noqa: E402
from app.database import engine  # noqa: E402
from app import models  # noqa: E402

client = TestClient(app)

VALID_JOB = {
    "title": "Backend Engineer",
    "description": "Build and maintain our core APIs.",
    "company": "TestCorp",
    "location": "Remote",
}


@pytest.fixture(autouse=True)
def clean_db():
    models.Base.metadata.drop_all(bind=engine)
    models.Base.metadata.create_all(bind=engine)
    yield


def test_health():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "healthy"


def test_create_job_valid_data_returns_201():
    response = client.post("/jobs", json=VALID_JOB)
    assert response.status_code == 201
    body = response.json()
    assert body["title"] == VALID_JOB["title"]
    assert "id" in body


def test_create_job_missing_fields_returns_422():
    response = client.post("/jobs", json={"title": "Backend Engineer"})
    assert response.status_code == 422


def test_get_job_nonexistent_id_returns_404():
    response = client.get("/jobs/does-not-exist")
    assert response.status_code == 404
