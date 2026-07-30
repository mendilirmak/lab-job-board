--
-- PostgreSQL database dump
--

\restrict QQPyj7XFQ2HimTUeyiXiHlhTbEao5Rw34ituH8USGAppfHqoqoYzbDA3HABzWjz

-- Dumped from database version 16.14
-- Dumped by pg_dump version 16.14

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: applications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.applications (
    id uuid NOT NULL,
    job_id character varying(255) NOT NULL,
    applicant_name character varying(200) NOT NULL,
    applicant_email character varying(200) NOT NULL,
    cover_letter text,
    status character varying(50) DEFAULT 'pending'::character varying,
    created_at timestamp without time zone DEFAULT now(),
    CONSTRAINT applications_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'reviewed'::character varying, 'accepted'::character varying, 'rejected'::character varying])::text[])))
);


--
-- Name: jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.jobs (
    id character varying(255) NOT NULL,
    title character varying(200) NOT NULL,
    description text NOT NULL,
    company character varying(200) NOT NULL,
    location character varying(200) NOT NULL,
    salary_range character varying(100),
    created_at timestamp with time zone DEFAULT now()
);


--
-- Data for Name: applications; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.applications (id, job_id, applicant_name, applicant_email, cover_letter, status, created_at) FROM stdin;
5bf890af-a3a4-4fc4-9543-c6230405276a	dbd3070b-e047-406a-9d5b-f935721fac45	Test User	test@lab.com	\N	pending	2026-07-30 10:14:56.329658
\.


--
-- Data for Name: jobs; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.jobs (id, title, description, company, location, salary_range, created_at) FROM stdin;
dbd3070b-e047-406a-9d5b-f935721fac45	Senior DevOps Engineer	Design and maintain cloud infrastructure using Kubernetes, Terraform, and CI/CD pipelines to ensure high availability.	TechCorp Ltd.	Remote	$120,000 - $160,000	2026-07-30 10:04:53.452538+00
89270515-4fc7-4497-84d9-7cda9e2f2198	Backend Developer (Python)	Build and maintain RESTful APIs using Python and FastAPI. Design PostgreSQL schemas and collaborate with frontend engineers.	StartupXYZ	Tel Aviv, Israel	$90,000 - $120,000	2026-07-30 10:04:53.558064+00
5e0b3a4b-f64e-4536-9299-3d3ec2403be9	Cloud Architect	Design cloud-native solutions on AWS and GCP. Lead architecture reviews and drive Infrastructure as Code adoption with Terraform.	CloudSystems Inc.	Hybrid – Berlin, Germany	$140,000 - $180,000	2026-07-30 10:04:53.85237+00
342b056b-f207-43bb-ae26-b2515172889c	Frontend Engineer (React)	Build performant web applications using React and TypeScript. Translate UX designs into accessible components.	ProductLab	Remote	$80,000 - $110,000	2026-07-30 10:04:53.950252+00
f89bfaa6-01e4-4700-baf6-03a7d73771f5	Security Engineer (DevSecOps)	Own security posture of the engineering organisation. Integrate SAST/DAST tools into CI/CD and run threat-modelling sessions.	SecureOps	London, UK	$130,000 - $165,000	2026-07-30 10:04:54.051638+00
bdad3fdc-5041-42e2-b29c-c0fd5f782bc9	K8s Persistence Test	This job must survive a pod restart	Lab Inc	Kubernetes	\N	2026-07-30 10:21:08.535806+00
\.


--
-- Name: applications applications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.applications
    ADD CONSTRAINT applications_pkey PRIMARY KEY (id);


--
-- Name: jobs jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_pkey PRIMARY KEY (id);


--
-- Name: idx_applications_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_applications_job_id ON public.applications USING btree (job_id);


--
-- Name: ix_jobs_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_jobs_id ON public.jobs USING btree (id);


--
-- PostgreSQL database dump complete
--

\unrestrict QQPyj7XFQ2HimTUeyiXiHlhTbEao5Rw34ituH8USGAppfHqoqoYzbDA3HABzWjz

