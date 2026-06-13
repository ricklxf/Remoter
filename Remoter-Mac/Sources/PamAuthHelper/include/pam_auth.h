#pragma once

/** Returns 0 (PAM_SUCCESS) if credentials are valid, non-zero otherwise. */
int pam_verify_password(const char *username, const char *password);
