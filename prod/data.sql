SET session_replication_role = replica;

--
-- PostgreSQL database dump
--

-- \restrict 1tJbiwH8pzXlzrVPLRSTwADPujdJhkINzdKBbVGG93Egek7ET76dJhNHGTp9T7K

-- Dumped from database version 17.11
-- Dumped by pg_dump version 17.11

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Data for Name: audit_log_entries; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."audit_log_entries" ("instance_id", "id", "payload", "created_at", "ip_address") FROM stdin;
\.


--
-- Data for Name: custom_oauth_providers; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."custom_oauth_providers" ("id", "provider_type", "identifier", "name", "client_id", "client_secret", "acceptable_client_ids", "scopes", "pkce_enabled", "attribute_mapping", "authorization_params", "enabled", "email_optional", "issuer", "discovery_url", "skip_nonce_check", "cached_discovery", "discovery_cached_at", "authorization_url", "token_url", "userinfo_url", "jwks_uri", "created_at", "updated_at", "custom_claims_allowlist") FROM stdin;
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."users" ("instance_id", "id", "aud", "role", "email", "encrypted_password", "email_confirmed_at", "invited_at", "confirmation_token", "confirmation_sent_at", "recovery_token", "recovery_sent_at", "email_change_token_new", "email_change", "email_change_sent_at", "last_sign_in_at", "raw_app_meta_data", "raw_user_meta_data", "is_super_admin", "created_at", "updated_at", "phone", "phone_confirmed_at", "phone_change", "phone_change_token", "phone_change_sent_at", "email_change_token_current", "email_change_confirm_status", "banned_until", "reauthentication_token", "reauthentication_sent_at", "is_sso_user", "deleted_at", "is_anonymous") FROM stdin;
00000000-0000-0000-0000-000000000000	10698111-1a49-4321-a796-48d8d9685f09	authenticated	authenticated	jgonzar09@gmail.com	\N	2026-10-23 03:27:56.97649+00	\N		\N		\N			\N	2026-11-16 00:31:43.181123+00	{"provider": "github", "providers": ["github"]}	{"iss": "https://api.github.com", "sub": "76130775", "name": "Ángel González", "email": "jgonzar09@gmail.com", "full_name": "Ángel González", "user_name": "jgonzar", "avatar_url": "https://avatars.githubusercontent.com/u/76130775?v=4", "provider_id": "76130775", "email_verified": true, "phone_verified": false, "preferred_username": "jgonzar"}	\N	2026-10-23 03:27:56.957826+00	2026-11-16 02:28:06.330818+00	\N	\N			\N		0	\N		\N	f	\N	f
00000000-0000-0000-0000-000000000000	00d4f221-c356-4386-8e20-f6eb722b7680	authenticated	authenticated	gabdiaz.pr@gmail.com	\N	2026-10-24 18:33:33.543103+00	\N		\N		\N			\N	2026-10-24 18:33:34.322411+00	{"provider": "github", "providers": ["github"]}	{"iss": "https://api.github.com", "sub": "229654380", "email": "gabdiaz.pr@gmail.com", "user_name": "Gabz021", "avatar_url": "https://avatars.githubusercontent.com/u/229654380?v=4", "provider_id": "229654380", "email_verified": true, "phone_verified": false, "preferred_username": "Gabz021"}	\N	2026-10-24 18:33:33.492776+00	2026-10-24 19:33:34.397667+00	\N	\N			\N		0	\N		\N	f	\N	f
\.


--
-- Data for Name: identities; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."identities" ("provider_id", "user_id", "identity_data", "provider", "last_sign_in_at", "created_at", "updated_at", "id") FROM stdin;
229654380	00d4f221-c356-4386-8e20-f6eb722b7680	{"iss": "https://api.github.com", "sub": "229654380", "email": "gabdiaz.pr@gmail.com", "user_name": "Gabz021", "avatar_url": "https://avatars.githubusercontent.com/u/229654380?v=4", "provider_id": "229654380", "email_verified": true, "phone_verified": false, "preferred_username": "Gabz021"}	github	2026-10-24 18:33:33.527982+00	2026-10-24 18:33:33.528048+00	2026-10-24 18:33:33.528048+00	751cfc0d-4a2f-4fbd-848f-b38812420bcb
76130775	10698111-1a49-4321-a796-48d8d9685f09	{"iss": "https://api.github.com", "sub": "76130775", "name": "Ángel González", "email": "jgonzar09@gmail.com", "full_name": "Ángel González", "user_name": "jgonzar", "avatar_url": "https://avatars.githubusercontent.com/u/76130775?v=4", "provider_id": "76130775", "email_verified": true, "phone_verified": false, "preferred_username": "jgonzar"}	github	2026-10-23 03:27:56.968557+00	2026-10-23 03:27:56.968633+00	2026-11-16 00:31:42.17836+00	279fad96-20f6-4e37-8df6-243899454469
\.


--
-- Data for Name: instances; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."instances" ("id", "uuid", "raw_base_config", "created_at", "updated_at") FROM stdin;
\.


--
-- Data for Name: mfa_factors; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."mfa_factors" ("id", "user_id", "friendly_name", "factor_type", "status", "created_at", "updated_at", "secret", "phone", "last_challenged_at", "web_authn_credential", "web_authn_aaguid", "last_webauthn_challenge_data") FROM stdin;
\.


--
-- Data for Name: mfa_recovery_code_sets; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."mfa_recovery_code_sets" ("id", "user_id", "mfa_factor_id", "failed_verification_count", "verification_locked_until", "created_at", "updated_at") FROM stdin;
\.


--
-- Data for Name: mfa_recovery_codes; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."mfa_recovery_codes" ("id", "mfa_recovery_code_set_id", "code_hash", "consumed_at", "created_at") FROM stdin;
\.


--
-- Data for Name: oauth_client_states; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."oauth_client_states" ("id", "provider_type", "code_verifier", "created_at") FROM stdin;
\.


--
-- Data for Name: oauth_clients; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."oauth_clients" ("id", "client_secret_hash", "registration_type", "redirect_uris", "grant_types", "client_name", "client_uri", "logo_uri", "created_at", "updated_at", "deleted_at", "client_type", "token_endpoint_auth_method") FROM stdin;
\.


--
-- Data for Name: oauth_consents; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."oauth_consents" ("id", "user_id", "client_id", "scopes", "granted_at", "revoked_at") FROM stdin;
\.


--
-- Data for Name: sso_providers; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."sso_providers" ("id", "resource_id", "created_at", "updated_at", "disabled") FROM stdin;
\.


--
-- Data for Name: saml_providers; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."saml_providers" ("id", "sso_provider_id", "entity_id", "metadata_xml", "metadata_url", "attribute_mapping", "created_at", "updated_at", "name_id_format", "dedicated_scope") FROM stdin;
\.


--
-- Data for Name: saml_relay_states; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."saml_relay_states" ("id", "sso_provider_id", "request_id", "for_email", "redirect_to", "created_at", "updated_at", "flow_state_id") FROM stdin;
\.


--
-- Data for Name: scim_tokens; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."scim_tokens" ("id", "sso_provider_id", "token_hash", "prefix", "created_at", "expires_at", "revoked_at", "last_used_at") FROM stdin;
\.


--
-- Data for Name: scim_users; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."scim_users" ("id", "sso_provider_id", "user_id", "resource", "created_at", "updated_at", "deleted_at") FROM stdin;
\.


--
-- Data for Name: sso_domains; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."sso_domains" ("id", "sso_provider_id", "domain", "created_at", "updated_at") FROM stdin;
\.


--
-- Data for Name: webauthn_challenges; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."webauthn_challenges" ("id", "user_id", "challenge_type", "session_data", "created_at", "expires_at") FROM stdin;
\.


--
-- Data for Name: webauthn_credentials; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

COPY "auth"."webauthn_credentials" ("id", "user_id", "credential_id", "public_key", "attestation_type", "aaguid", "sign_count", "transports", "backup_eligible", "backed_up", "friendly_name", "created_at", "updated_at", "last_used_at") FROM stdin;
\.


--
-- Data for Name: members; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."members" ("id", "github_login", "display_name", "role", "created_at", "avatar_url", "last_seen_at") FROM stdin;
00d4f221-c356-4386-8e20-f6eb722b7680	Gabz021	Gabriel Diaz	member	2026-10-24 19:34:19.654267+00	\N	\N
10698111-1a49-4321-a796-48d8d9685f09	jgonzar	Ángel González	admin	2026-10-23 04:13:29.604316+00	\N	2026-11-16 00:33:34.450025+00
\.


--
-- Data for Name: spaces; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."spaces" ("id", "name", "slug", "pitch_item_id", "pitch_kind", "cover_file_id", "is_studio", "facts_item_id", "facts_kind", "archived_at", "created_by", "created_at") FROM stdin;
9e2fb9d0-d2e8-44ac-bd20-131d529ce445	Studio	studio	\N	doc	\N	t	debcf642-6d60-46e8-9404-d5a8d9ae700e	doc	\N	\N	2026-10-24 20:59:37.997634+00
\.


--
-- Data for Name: items; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."items" ("id", "number", "kind", "title", "space_id", "content_json", "content_md", "version", "created_by", "created_via", "created_at", "updated_by", "updated_at", "archived_at") FROM stdin;
debcf642-6d60-46e8-9404-d5a8d9ae700e	1	doc	Studio facts	9e2fb9d0-d2e8-44ac-bd20-131d529ce445	\N		1	\N	app	2026-10-24 20:59:37.997634+00	\N	2026-10-24 20:59:37.997634+00	\N
9d11f6b0-8859-4ca5-a587-dd4b2e725f4a	2	task	test task	9e2fb9d0-d2e8-44ac-bd20-131d529ce445	\N		1	10698111-1a49-4321-a796-48d8d9685f09	app	2026-11-15 22:56:24.854059+00	10698111-1a49-4321-a796-48d8d9685f09	2026-11-15 22:56:24.854059+00	\N
744be59a-1fa0-4201-bcbf-867615d6ba6c	3	idea	fewefij	\N	\N	ierhoifrih	1	10698111-1a49-4321-a796-48d8d9685f09	app	2026-11-15 23:35:19.266266+00	10698111-1a49-4321-a796-48d8d9685f09	2026-11-15 23:35:19.266266+00	\N
f66f8acf-ae1a-4fd9-9947-2c7588db7762	4	task	Jel	\N	\N		1	10698111-1a49-4321-a796-48d8d9685f09	app	2026-11-16 00:32:01.278469+00	10698111-1a49-4321-a796-48d8d9685f09	2026-11-16 00:32:01.278469+00	\N
\.


--
-- Data for Name: sources; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."sources" ("id", "title", "origin", "raw_text", "cleaned_md", "processing_notes", "external_ref", "space_id", "created_by", "created_via", "created_at") FROM stdin;
\.


--
-- Data for Name: activity; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."activity" ("id", "at", "actor_id", "actor_via", "verb", "item_id", "space_id", "source_id", "data") FROM stdin;
1	2026-10-24 20:59:37.997634+00	\N	app	space_created	\N	9e2fb9d0-d2e8-44ac-bd20-131d529ce445	\N	{}
2	2026-11-15 22:56:24.854059+00	10698111-1a49-4321-a796-48d8d9685f09	app	created	9d11f6b0-8859-4ca5-a587-dd4b2e725f4a	9e2fb9d0-d2e8-44ac-bd20-131d529ce445	\N	{}
3	2026-11-15 22:57:12.713803+00	10698111-1a49-4321-a796-48d8d9685f09	app	commented	9d11f6b0-8859-4ca5-a587-dd4b2e725f4a	9e2fb9d0-d2e8-44ac-bd20-131d529ce445	\N	{"comment_id": "01e05688-2b73-4c20-9ac3-13ee1593a4b7"}
4	2026-11-15 23:35:19.266266+00	10698111-1a49-4321-a796-48d8d9685f09	app	created	744be59a-1fa0-4201-bcbf-867615d6ba6c	\N	\N	{}
5	2026-11-16 00:32:01.278469+00	10698111-1a49-4321-a796-48d8d9685f09	app	created	f66f8acf-ae1a-4fd9-9947-2c7588db7762	\N	\N	{}
\.


--
-- Data for Name: comments; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."comments" ("id", "item_id", "author_id", "body_md", "created_at", "edited_at", "deleted_at") FROM stdin;
01e05688-2b73-4c20-9ac3-13ee1593a4b7	9d11f6b0-8859-4ca5-a587-dd4b2e725f4a	10698111-1a49-4321-a796-48d8d9685f09	Test	2026-11-15 22:57:12.713803+00	\N	\N
\.


--
-- Data for Name: docs; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."docs" ("item_id", "kind", "state", "sealed_by", "sealed_at") FROM stdin;
debcf642-6d60-46e8-9404-d5a8d9ae700e	doc	draft	\N	\N
\.


--
-- Data for Name: files; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."files" ("id", "status", "mime", "bytes", "width", "height", "name", "space_id", "uploaded_by", "created_at") FROM stdin;
ca46e8b7-c120-4514-9de3-7f58781d07f3	ready	image/webp	2274	72	72	avatar.png	\N	10698111-1a49-4321-a796-48d8d9685f09	2026-11-15 22:56:51.232638+00
bb8fb29e-e39a-4435-8d68-b8bca4cb28bb	ready	image/webp	2274	72	72	avatar.png	\N	10698111-1a49-4321-a796-48d8d9685f09	2026-11-15 23:35:19.574895+00
\.


--
-- Data for Name: ideas; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."ideas" ("item_id", "kind", "status", "decided_by", "decided_at", "cut_reason", "consolidated_into", "consolidated_kind") FROM stdin;
744be59a-1fa0-4201-bcbf-867615d6ba6c	idea	\N	{}	\N	\N	\N	doc
\.


--
-- Data for Name: item_files; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."item_files" ("item_id", "file_id", "role", "created_at") FROM stdin;
9d11f6b0-8859-4ca5-a587-dd4b2e725f4a	ca46e8b7-c120-4514-9de3-7f58781d07f3	attachment	2026-11-15 22:56:53.260134+00
744be59a-1fa0-4201-bcbf-867615d6ba6c	bb8fb29e-e39a-4435-8d68-b8bca4cb28bb	attachment	2026-11-15 23:35:21.644988+00
\.


--
-- Data for Name: item_links; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."item_links" ("from_item", "to_item", "type", "created_by", "created_at") FROM stdin;
\.


--
-- Data for Name: item_sources; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."item_sources" ("id", "item_id", "source_id", "quote", "created_by", "created_at", "quote_translation") FROM stdin;
\.


--
-- Data for Name: item_versions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."item_versions" ("id", "item_id", "version", "title", "content_json", "content_md", "created_by", "created_at") FROM stdin;
\.


--
-- Data for Name: proposals; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."proposals" ("id", "source_id", "batch_index", "kind", "title", "summary_md", "quote", "confidence", "suggested_space_id", "suggested_assignee_id", "suggested_due_date", "possible_duplicate_of", "state", "resulting_item_id", "proposed_by", "created_via", "triaged_by", "triaged_at", "created_at", "quote_translation") FROM stdin;
\.


--
-- Data for Name: tasks; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."tasks" ("item_id", "kind", "status", "assignee_id", "due_date", "origin_idea_id", "origin_kind", "completed_at") FROM stdin;
9d11f6b0-8859-4ca5-a587-dd4b2e725f4a	task	todo	\N	\N	\N	idea	\N
f66f8acf-ae1a-4fd9-9947-2c7588db7762	task	todo	\N	\N	\N	idea	\N
\.


--
-- Data for Name: buckets; Type: TABLE DATA; Schema: storage; Owner: supabase_storage_admin
--

COPY "storage"."buckets" ("id", "name", "owner", "created_at", "updated_at", "public", "avif_autodetection", "file_size_limit", "allowed_mime_types", "owner_id", "type", "versioning_status", "lifecycle_configuration", "lifecycle_configuration_generation") FROM stdin;
\.


--
-- Data for Name: buckets_analytics; Type: TABLE DATA; Schema: storage; Owner: supabase_storage_admin
--

COPY "storage"."buckets_analytics" ("name", "type", "format", "created_at", "updated_at", "id", "deleted_at") FROM stdin;
\.


--
-- Data for Name: buckets_vectors; Type: TABLE DATA; Schema: storage; Owner: supabase_storage_admin
--

COPY "storage"."buckets_vectors" ("id", "type", "created_at", "updated_at") FROM stdin;
\.


--
-- Data for Name: objects; Type: TABLE DATA; Schema: storage; Owner: supabase_storage_admin
--

COPY "storage"."objects" ("id", "bucket_id", "name", "owner", "created_at", "updated_at", "last_accessed_at", "metadata", "version", "owner_id", "user_metadata", "archived_at", "is_delete_marker", "is_versioned") FROM stdin;
\.


--
-- Data for Name: s3_multipart_uploads; Type: TABLE DATA; Schema: storage; Owner: supabase_storage_admin
--

COPY "storage"."s3_multipart_uploads" ("id", "in_progress_size", "upload_signature", "bucket_id", "key", "version", "owner_id", "created_at", "user_metadata", "metadata") FROM stdin;
\.


--
-- Data for Name: s3_multipart_uploads_parts; Type: TABLE DATA; Schema: storage; Owner: supabase_storage_admin
--

COPY "storage"."s3_multipart_uploads_parts" ("id", "upload_id", "size", "part_number", "bucket_id", "key", "etag", "owner_id", "version", "created_at") FROM stdin;
\.


--
-- Data for Name: vector_indexes; Type: TABLE DATA; Schema: storage; Owner: supabase_storage_admin
--

COPY "storage"."vector_indexes" ("id", "name", "bucket_id", "data_type", "dimension", "distance_metric", "metadata_configuration", "created_at", "updated_at") FROM stdin;
\.


--
-- Name: refresh_tokens_id_seq; Type: SEQUENCE SET; Schema: auth; Owner: supabase_auth_admin
--

SELECT pg_catalog.setval('"auth"."refresh_tokens_id_seq"', 10, true);


--
-- Name: activity_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('"public"."activity_id_seq"', 5, true);


--
-- Name: items_number_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('"public"."items_number_seq"', 4, true);


--
-- PostgreSQL database dump complete
--

-- \unrestrict 1tJbiwH8pzXlzrVPLRSTwADPujdJhkINzdKBbVGG93Egek7ET76dJhNHGTp9T7K

RESET ALL;
