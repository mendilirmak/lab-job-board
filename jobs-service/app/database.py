import os
from urllib.parse import quote
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, DeclarativeBase


def _build_database_url() -> str:
    # Explicit DATABASE_URL always wins (used by local dev overrides and tests,
    # e.g. pointing at a SQLite file instead of Postgres).
    if os.getenv("DATABASE_URL"):
        return os.environ["DATABASE_URL"]

    password_file = os.getenv("POSTGRES_PASSWORD_FILE")
    if password_file:
        with open(password_file, "r", encoding="utf-8") as f:
            password = f.read().strip()
        host = os.getenv("POSTGRES_HOST", "localhost")
        port = os.getenv("POSTGRES_PORT", "5432")
        user = os.getenv("POSTGRES_USER", "postgres")
        db = os.getenv("POSTGRES_DB", "jobboard")
        return f"postgresql://{user}:{quote(password, safe='')}@{host}:{port}/{db}"

    return "postgresql://postgres:jobboard123@localhost:5432/jobboard"


DATABASE_URL = _build_database_url()

engine = create_engine(DATABASE_URL, pool_pre_ping=True)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


class Base(DeclarativeBase):
    pass


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
