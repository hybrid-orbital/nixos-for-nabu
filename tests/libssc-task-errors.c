/* Exercise the actual libssc callbacks using real GTask ownership/reentrancy.
 * Only the SSC transport is replaced; no DSP or ARM machine is required.
 */
#include <gio/gio.h>
typedef GObject SSCClient;
static gboolean fail_request;
static gboolean completed;
static gboolean inside_ready;
static guint messages;
static gboolean ssc_client_send_finish(SSCClient *client, GAsyncResult *result, GError **error)
{
    (void)client; (void)result;
    if (fail_request) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_CLOSED, "SSC endpoint disappeared");
        return FALSE;
    }
    return TRUE;
}
#include "callbacks-under-test.h"
static void log_message(const gchar *domain, GLogLevelFlags level,
                        const gchar *message, gpointer data)
{
    (void)domain; (void)level; (void)data;
    g_assert_nonnull(message);
    if (fail_request)
        g_assert_nonnull(g_strstr_len(message, -1, "SSC endpoint disappeared"));
    messages++;
}
static void finished(GObject *source, GAsyncResult *result, gpointer data)
{
    GError *error = NULL;
    (void)source; (void)data;
    /* The GTask was created before entering this main-loop iteration. Its
     * completion runs inline, allowing this callback to free the error.
     */
    g_assert_true(inside_ready);
    g_assert_cmpuint(messages, ==, 1);
    g_assert_cmpint(g_task_propagate_boolean(G_TASK(result), &error), ==, !fail_request);
    if (fail_request) {
        g_assert_error(error, G_IO_ERROR, G_IO_ERROR_CLOSED);
        g_assert_cmpstr(error->message, ==, "SSC endpoint disappeared");
        g_clear_error(&error);
    } else {
        g_assert_no_error(error);
    }
    completed = TRUE;
}
struct request { GTask *task; gboolean open; };
static gboolean dispatch(gpointer data)
{
    struct request *request = data;
    inside_ready = TRUE;
    if (request->open)
        sensor_open_ready(NULL, NULL, request->task);
    else
        sensor_close_ready(NULL, NULL, request->task);
    if (request->open && !fail_request) {
        /* Open succeeds later, on the first sensor report; this callback
         * deliberately leaves the task pending on a successful send. */
        g_assert_false(completed);
        g_assert_cmpuint(messages, ==, 1);
        /* Stand in for that later report so GTask is finalized normally. */
        g_task_return_boolean(request->task, TRUE);
        g_object_unref(request->task);
    }
    inside_ready = FALSE;
    return G_SOURCE_REMOVE;
}
int main(void)
{
    g_log_set_handler(NULL, G_LOG_LEVEL_DEBUG, log_message, NULL);
    for (int open = 0; open < 2; open++) {
        for (int fail = 0; fail < 2; fail++) {
            fail_request = fail;
            completed = FALSE;
            messages = 0;
            struct request request = { g_task_new(NULL, NULL, finished, NULL), open };
            g_idle_add(dispatch, &request);
            while (!completed)
                g_main_context_iteration(NULL, TRUE);
        }
    }
    g_print("libssc open/close: success and reentrant error ownership passed\n");
}
