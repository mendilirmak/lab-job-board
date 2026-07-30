'use strict';

const fs = require('fs');
const { Pool } = require('pg');

function buildDatabaseUrl() {
  // Explicit DATABASE_URL always wins (local dev override / tests).
  if (process.env.DATABASE_URL) {
    return process.env.DATABASE_URL;
  }

  const passwordFile = process.env.POSTGRES_PASSWORD_FILE;
  if (passwordFile) {
    const password = fs.readFileSync(passwordFile, 'utf8').trim();
    const host = process.env.POSTGRES_HOST || 'localhost';
    const port = process.env.POSTGRES_PORT || '5432';
    const user = process.env.POSTGRES_USER || 'postgres';
    const db = process.env.POSTGRES_DB || 'jobboard';
    return `postgresql://${user}:${encodeURIComponent(password)}@${host}:${port}/${db}`;
  }

  return 'postgresql://postgres:jobboard123@localhost:5432/jobboard';
}

const pool = new Pool({
  connectionString: buildDatabaseUrl(),
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

pool.on('error', (err) => {
  console.error('Unexpected database pool error:', err.message);
});

async function initDB() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS applications (
      id              UUID         PRIMARY KEY,
      job_id          VARCHAR(255) NOT NULL,
      applicant_name  VARCHAR(200) NOT NULL,
      applicant_email VARCHAR(200) NOT NULL,
      cover_letter    TEXT,
      status          VARCHAR(50)  DEFAULT 'pending'
                      CHECK (status IN ('pending', 'reviewed', 'accepted', 'rejected')),
      created_at      TIMESTAMP    DEFAULT NOW()
    )
  `);

  await pool.query(`
    CREATE INDEX IF NOT EXISTS idx_applications_job_id ON applications(job_id)
  `);

  console.log('[db] Applications table ready');
}

module.exports = { pool, initDB };
