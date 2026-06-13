#include "pam_auth.h"
#include <security/pam_appl.h>
#include <stdlib.h>
#include <string.h>

/* Single-threaded: auth is called sequentially so a global password is safe. */
static const char *g_password = NULL;

static int conv_fn(int num_msg, const struct pam_message **msg,
                   struct pam_response **resp, void *appdata_ptr) {
    (void)appdata_ptr;
    *resp = calloc((size_t)num_msg, sizeof(struct pam_response));
    if (!*resp) return PAM_BUF_ERR;
    for (int i = 0; i < num_msg; i++) {
        int style = msg[i]->msg_style;
        if (style == PAM_PROMPT_ECHO_OFF || style == PAM_PROMPT_ECHO_ON) {
            (*resp)[i].resp = strdup(g_password ? g_password : "");
        }
    }
    return PAM_SUCCESS;
}

int pam_verify_password(const char *username, const char *password) {
    g_password = password;
    struct pam_conv conv = { conv_fn, NULL };
    pam_handle_t *pamh = NULL;
    /* "screensaver" uses pam_opendirectory.so without requiring root,
       unlike "login" which fails for non-privileged processes on macOS. */
    int result = pam_start("screensaver", username, &conv, &pamh);
    if (result == PAM_SUCCESS) {
        result = pam_authenticate(pamh, 0);
        pam_end(pamh, result);
    }
    g_password = NULL;
    return result;   /* PAM_SUCCESS (0) = OK */
}
