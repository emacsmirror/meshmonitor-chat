;;; meshmonitor-chat.el --- Chat client for MeshMonitor (Meshtastic) -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Andros Fenollosa

;; Author: Andros Fenollosa <andros@fenollosa.email>
;; Maintainer: Andros Fenollosa <andros@fenollosa.email>
;; Version: 1.0.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: comm
;; URL: https://git.andros.dev/andros/meshmonitor-chat.el

;;; Commentary:

;; Emacs chat client for MeshMonitor, a web-based Meshtastic network
;; monitor.  Provides channel and direct message chat buffers.
;;
;; Configure `meshmonitor-chat-host', `meshmonitor-chat-port' and
;; `meshmonitor-chat-token' in your init file.  Then:
;;
;;   M-x meshmonitor-chat-channels        - list channels
;;   M-x meshmonitor-chat-nodes           - list nodes by hops
;;   M-x meshmonitor-chat-unread          - nodes with unread DMs
;;   M-x meshmonitor-chat-direct-messages - list DM conversations

;;; Code:

(require 'json)
(require 'url)
(require 'url-http)
(require 'cl-lib)
(require 'notifications)
(require 'ring)
(require 'seq)

;;;; Customization

(defgroup meshmonitor-chat nil
  "Chat client for MeshMonitor (Meshtastic)."
  :group 'communication
  :prefix "meshmonitor-chat-")

(defcustom meshmonitor-chat-host ""
  "MeshMonitor server hostname or IP address."
  :type 'string)

(defcustom meshmonitor-chat-port 3000
  "MeshMonitor server port."
  :type 'integer)

(defcustom meshmonitor-chat-use-tls nil
  "Non-nil means use HTTPS instead of HTTP."
  :type 'boolean)

(defcustom meshmonitor-chat-token nil
  "Bearer token for MeshMonitor API.
When set, username/password login is skipped."
  :type '(choice (const nil) string))

(defcustom meshmonitor-chat-username "admin"
  "Username for MeshMonitor authentication."
  :type 'string)

(defcustom meshmonitor-chat-password ""
  "Password for MeshMonitor authentication."
  :type 'string)

(defcustom meshmonitor-chat-login-endpoint "/auth/login"
  "API endpoint path for login."
  :type 'string)

(defcustom meshmonitor-chat-poll-interval 10
  "Seconds between polling for new messages."
  :type 'integer)

(defcustom meshmonitor-chat-notify t
  "Non-nil means show desktop notifications for new messages."
  :type 'boolean)

(defcustom meshmonitor-chat-message-limit 50
  "Number of messages to fetch per request."
  :type 'integer)

(defcustom meshmonitor-chat-timestamp-format "%H:%M"
  "Format string for message timestamps."
  :type 'string)

;;;; Faces

(defface meshmonitor-chat-timestamp-face
  '((t :foreground "gray50"))
  "Face for message timestamps.")

(defface meshmonitor-chat-nick-self-face
  '((t :foreground "sea green" :weight bold))
  "Face for own nick in messages.")

(defface meshmonitor-chat-nick-other-face
  '((t :foreground "dodger blue" :weight bold))
  "Face for other nicks in messages.")

(defface meshmonitor-chat-prompt-face
  '((t :foreground "cyan" :weight bold))
  "Face for the input prompt.")

(defface meshmonitor-chat-system-face
  '((t :foreground "gray60" :slant italic))
  "Face for system messages.")

(defface meshmonitor-chat-delivery-pending-face
  '((t :foreground "gray50"))
  "Face for pending delivery icon.")

(defface meshmonitor-chat-delivery-confirmed-face
  '((t :foreground "green"))
  "Face for confirmed delivery icon.")

(defface meshmonitor-chat-delivery-failed-face
  '((t :foreground "red"))
  "Face for failed delivery icon.")

;;;; Internal state

(defvar meshmonitor-chat--base-url nil
  "Base URL for the MeshMonitor instance.")

(defvar meshmonitor-chat--auth-token nil
  "Bearer token for API requests.")

(defvar meshmonitor-chat--connected nil
  "Non-nil when connected to MeshMonitor.")

(defvar meshmonitor-chat--nodes (make-hash-table :test 'equal)
  "Hash table mapping node IDs and nums to node alists.")

(defvar meshmonitor-chat--my-node-id nil
  "Node ID of the connected MeshMonitor node.")

(defvar meshmonitor-chat--my-node-num nil
  "Node number of the connected MeshMonitor node.")

(defvar meshmonitor-chat--channels nil
  "Cached list of channel alists from the API.")

(defvar meshmonitor-chat--chat-buffers nil
  "Alist of ((TYPE . TARGET) . BUFFER) for open chat buffers.")

(defvar meshmonitor-chat--read-timestamps (make-hash-table :test 'equal)
  "Hash table mapping node IDs to last-read Unix timestamp.")

(defvar meshmonitor-chat--poll-timer nil
  "Timer for periodic message polling.")

;;;; Buffer-local variables

(defvar-local meshmonitor-chat--target nil
  "Target for this buffer: channel number or node ID string.")

(defvar-local meshmonitor-chat--target-type nil
  "Type of target: symbol `channel' or `dm'.")

(defvar-local meshmonitor-chat--prompt-start nil
  "Marker at the beginning of the prompt.")

(defvar-local meshmonitor-chat--prompt-end nil
  "Marker at the end of the prompt.")

(defvar-local meshmonitor-chat--last-timestamp nil
  "Unix timestamp of the last rendered message.")

(defvar-local meshmonitor-chat--seen-ids nil
  "Hash table of rendered message IDs for deduplication.")

(defvar-local meshmonitor-chat--input-ring nil
  "Ring holding previous input strings.")

(defvar-local meshmonitor-chat--input-ring-index 0
  "Current index in the input ring.")

(defvar-local meshmonitor-chat--pending-deliveries nil
  "Alist of (REQUEST-ID . MARKER) for pending delivery icons.")

(defvar-local meshmonitor-chat--reply-to nil
  "Cons of (REQUEST-ID . SENDER-NAME) for the message being replied to.")

;;;; Timestamp helpers

(defun meshmonitor-chat--parse-timestamp (ts)
  "Convert TS to a Unix timestamp in seconds.
Handles millisecond timestamps from MeshMonitor API."
  (cond
   ((numberp ts)
    (if (> ts 9999999999) (/ ts 1000) ts))
   ((stringp ts)
    (condition-case nil
        (truncate (float-time (date-to-time ts)))
      (error 0)))
   (t 0)))

(defun meshmonitor-chat--format-time (ts)
  "Format timestamp TS for display."
  (condition-case nil
      (format-time-string
       meshmonitor-chat-timestamp-format
       (seconds-to-time (meshmonitor-chat--parse-timestamp ts)))
    (error "??:??")))

;;;; HTTP helpers

(defun meshmonitor-chat--build-url (endpoint)
  "Build full URL for API ENDPOINT."
  (concat meshmonitor-chat--base-url endpoint))

(defun meshmonitor-chat--request (method endpoint &optional data callback)
  "Make an HTTP request with METHOD to ENDPOINT.
DATA is an alist to send as JSON body.
When CALLBACK is non-nil, make an async request and call
CALLBACK with (STATUS-CODE . JSON-BODY) or nil on error.
When CALLBACK is nil, make a synchronous request and return
the same cons cell."
  (let ((url-request-method method)
        (url-cookie-confirmation nil)
        (url-request-extra-headers
         (append '(("Content-Type" . "application/json")
                   ("Accept" . "application/json"))
                 (when meshmonitor-chat--auth-token
                   `(("Authorization"
                      . ,(concat "Bearer "
                                 meshmonitor-chat--auth-token))))))
        (url-request-data
         (when data
           (encode-coding-string (json-encode data) 'utf-8)))
        (full-url (meshmonitor-chat--build-url endpoint)))
    (if callback
        (url-retrieve
         full-url
         (lambda (status cb)
           (let ((result nil)
                 (resp-buf (current-buffer)))
             (unwind-protect
                 (progn
                   (unless (plist-get status :error)
                     (setq result
                           (meshmonitor-chat--parse-response)))
                   (funcall cb result))
               (when (buffer-live-p resp-buf)
                 (kill-buffer resp-buf)))))
         (list callback) t)
      (let ((buf (url-retrieve-synchronously full-url t nil 15)))
        (when buf
          (unwind-protect
              (with-current-buffer buf
                (meshmonitor-chat--parse-response))
            (kill-buffer buf)))))))

(defun meshmonitor-chat--parse-response ()
  "Parse HTTP response in current buffer.
Return (STATUS-CODE . JSON-BODY) or (STATUS-CODE . nil)."
  (goto-char (point-min))
  (let ((status-code 0))
    (when (re-search-forward "HTTP/[0-9.]+ \\([0-9]+\\)" nil t)
      (setq status-code (string-to-number (match-string 1))))
    (goto-char (point-min))
    (if (re-search-forward "\r?\n\r?\n" nil t)
        (condition-case nil
            (progn
              ;; url.el returns a unibyte buffer; convert to
              ;; multibyte so json-read decodes UTF-8 correctly.
              (set-buffer-multibyte t)
              (let ((json-object-type 'alist)
                    (json-array-type 'list)
                    (json-key-type 'symbol))
                (cons status-code (json-read))))
          (error (cons status-code nil)))
      (cons status-code nil))))

;;;; Authentication and connection

(defun meshmonitor-chat--login ()
  "Login to MeshMonitor using configured credentials.
Return non-nil on success."
  (let ((scheme (if meshmonitor-chat-use-tls "https" "http")))
    (setq meshmonitor-chat--base-url
          (format "%s://%s:%d" scheme
                  meshmonitor-chat-host
                  meshmonitor-chat-port)))
  (cond
   (meshmonitor-chat-token
    (setq meshmonitor-chat--auth-token meshmonitor-chat-token)
    t)
   (t
    (let ((result (meshmonitor-chat--request
                   "POST" meshmonitor-chat-login-endpoint
                   `((username . ,meshmonitor-chat-username)
                     (password . ,meshmonitor-chat-password)))))
      (when result
        (let ((body (cdr result)))
          (when body
            (let ((token (or (alist-get 'token body)
                             (alist-get 'accessToken body))))
              (when token
                (setq meshmonitor-chat--auth-token token)))))
        (< (car result) 400))))))

(defun meshmonitor-chat--ensure-connected ()
  "Ensure connection to MeshMonitor, auto-connecting if needed."
  (unless meshmonitor-chat--connected
    (when (string-empty-p meshmonitor-chat-host)
      (user-error "Set `meshmonitor-chat-host' in your init file"))
    (unless (meshmonitor-chat--login)
      (user-error "MeshMonitor: login failed at %s"
                  meshmonitor-chat--base-url))
    (setq meshmonitor-chat--connected t)
    ;; Fetch status (sync) for our node identity.
    (let ((info (meshmonitor-chat--request "GET" "/api/status")))
      (when info
        (let* ((body (cdr info))
               (conn (alist-get 'connection body))
               (local-node (alist-get 'localNode conn)))
          (when local-node
            (setq meshmonitor-chat--my-node-id
                  (alist-get 'nodeId local-node))
            (setq meshmonitor-chat--my-node-num
                  (alist-get 'nodeNum local-node))))))
    ;; Fetch nodes (sync) for name resolution.
    (meshmonitor-chat--fetch-nodes-sync)
    ;; Fetch channels (sync).
    (meshmonitor-chat--fetch-channels-sync)
    ;; Start polling.
    (meshmonitor-chat--start-polling)
    (message "MeshMonitor: connected to %s" meshmonitor-chat-host))
  t)

;;;; Node resolution

(defun meshmonitor-chat--process-nodes (data)
  "Process and cache node DATA list."
  (when (listp data)
    (clrhash meshmonitor-chat--nodes)
    (dolist (node data)
      (let ((num (alist-get 'nodeNum node))
            (id (alist-get 'nodeId node)))
        (when num
          (puthash (number-to-string num) node
                   meshmonitor-chat--nodes))
        (when id
          (puthash id node meshmonitor-chat--nodes))))))

(defun meshmonitor-chat--fetch-nodes-sync ()
  "Fetch and cache nodes synchronously."
  (let ((result (meshmonitor-chat--request "GET" "/api/v1/nodes")))
    (when result
      (meshmonitor-chat--process-nodes
       (alist-get 'data (cdr result))))))

(defun meshmonitor-chat--fetch-nodes (&optional callback)
  "Fetch and cache nodes asynchronously.
Call CALLBACK with no arguments when done."
  (meshmonitor-chat--request
   "GET" "/api/v1/nodes" nil
   (lambda (result)
     (when result
       (meshmonitor-chat--process-nodes
        (alist-get 'data (cdr result))))
     (when callback (funcall callback)))))

(defun meshmonitor-chat--node-name (id)
  "Return display name for node ID.
Falls back to ID itself when no name is cached."
  (let* ((key (if (numberp id) (number-to-string id) (or id "")))
         (node (gethash key meshmonitor-chat--nodes)))
    (if node
        (or (alist-get 'longName node)
            (alist-get 'shortName node)
            key)
      key)))

;;;; Channel helpers

(defun meshmonitor-chat--fetch-channels-sync ()
  "Fetch and cache channels synchronously."
  (let ((result (meshmonitor-chat--request
                 "GET" "/api/v1/channels")))
    (when result
      (setq meshmonitor-chat--channels
            (alist-get 'data (cdr result))))))

(defun meshmonitor-chat--fetch-channels (&optional callback)
  "Fetch channels asynchronously.
Call CALLBACK with the channel list when done."
  (meshmonitor-chat--request
   "GET" "/api/v1/channels" nil
   (lambda (result)
     (when result
       (setq meshmonitor-chat--channels
             (alist-get 'data (cdr result))))
     (when callback
       (funcall callback meshmonitor-chat--channels)))))

(defun meshmonitor-chat--channel-name (id)
  "Return display name for channel ID."
  (let ((ch (seq-find (lambda (c) (equal (alist-get 'id c) id))
                      meshmonitor-chat--channels)))
    (if ch
        (or (let ((name (alist-get 'name ch)))
              (and name (not (string-empty-p name)) name))
            (format "%d" id))
      (format "%d" id))))

;;;; API wrappers

(defun meshmonitor-chat--api-messages (params callback)
  "Fetch messages with query PARAMS alist.
Call CALLBACK with (STATUS . BODY)."
  (let ((query (mapconcat
                (lambda (p)
                  (format "%s=%s"
                          (url-hexify-string (symbol-name (car p)))
                          (url-hexify-string (format "%s" (cdr p)))))
                params "&")))
    (meshmonitor-chat--request
     "GET" (concat "/api/v1/messages?" query) nil callback)))

(defun meshmonitor-chat--api-send (text &optional channel to-node
                                             reply-id callback)
  "Send TEXT message to CHANNEL or TO-NODE.
REPLY-ID is the requestId of the message being replied to.
Call CALLBACK with (STATUS . BODY)."
  (let ((data `((text . ,text))))
    (when channel (push `(channel . ,channel) data))
    (when to-node (push `(toNodeId . ,to-node) data))
    (when reply-id (push `(replyId . ,reply-id) data))
    (meshmonitor-chat--request
     "POST" "/api/v1/messages" data callback)))

;;;; Delivery icons

(defun meshmonitor-chat--delivery-icon (state)
  "Return propertized delivery icon string for STATE."
  (let ((icon (pcase state
                ('confirmed "✓")
                ('failed "✗")
                (_ "·")))
        (face (pcase state
                ('confirmed 'meshmonitor-chat-delivery-confirmed-face)
                ('failed 'meshmonitor-chat-delivery-failed-face)
                (_ 'meshmonitor-chat-delivery-pending-face))))
    (propertize icon 'face face 'read-only t 'rear-nonsticky t)))

(defun meshmonitor-chat--update-delivery-icon (request-id state)
  "Update delivery icon for REQUEST-ID to STATE in current buffer."
  (let ((entry (assoc request-id meshmonitor-chat--pending-deliveries)))
    (when entry
      (let ((marker (cdr entry))
            (inhibit-read-only t))
        (when (and marker (marker-buffer marker))
          (save-excursion
            (goto-char marker)
            (delete-char 1)
            (insert (meshmonitor-chat--delivery-icon state))
            (set-marker marker (1- (point))))))
      (unless (eq state 'pending)
        (setq meshmonitor-chat--pending-deliveries
              (delq entry meshmonitor-chat--pending-deliveries))))))

(defun meshmonitor-chat--check-delivery (msg buffer)
  "Check if MSG confirms delivery of a pending message in BUFFER."
  (when (buffer-live-p buffer)
    (let ((req-id (alist-get 'requestId msg)))
      (when req-id
        (with-current-buffer buffer
          (when (assoc req-id meshmonitor-chat--pending-deliveries)
            (let ((state (cond
                          ((equal (alist-get 'ackFailed msg) 1)
                           'failed)
                          ((member (alist-get 'deliveryState msg)
                                   '("confirmed" "delivered"))
                           'confirmed)
                          (t nil))))
              (when state
                (meshmonitor-chat--update-delivery-icon
                 req-id state)
                ;; Prevent re-render of delivered message.
                (let ((msg-id (alist-get 'id msg)))
                  (when msg-id
                    (puthash msg-id t
                             meshmonitor-chat--seen-ids)))))))))))

;;;; Chat mode

(defvar meshmonitor-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'meshmonitor-chat-send-input)
    (define-key map (kbd "M-p") #'meshmonitor-chat-previous-input)
    (define-key map (kbd "M-n") #'meshmonitor-chat-next-input)
    (define-key map (kbd "C-c C-r") #'meshmonitor-chat-resend)
    (define-key map (kbd "C-c C-p") #'meshmonitor-chat-reply)
    (define-key map (kbd "C-c C-e") #'meshmonitor-chat-react)
    (define-key map (kbd "C-c C-k") #'meshmonitor-chat-cancel-reply)
    map)
  "Keymap for `meshmonitor-chat-mode'.")

(define-derived-mode meshmonitor-chat-mode fundamental-mode "MeshChat"
  "Major mode for MeshMonitor chat buffers.
Provides an input prompt at the bottom with message history above."
  :group 'meshmonitor-chat
  (setq-local meshmonitor-chat--prompt-start (make-marker))
  (setq-local meshmonitor-chat--prompt-end (make-marker))
  (setq-local meshmonitor-chat--input-ring (make-ring 64))
  (setq-local meshmonitor-chat--input-ring-index 0)
  (setq-local meshmonitor-chat--seen-ids
              (make-hash-table :test 'equal))
  (setq-local meshmonitor-chat--pending-deliveries nil)
  (setq-local meshmonitor-chat--last-timestamp nil)
  (setq mode-line-process
        '(" " (:eval (meshmonitor-chat--mode-line-status))))
  (add-hook 'post-command-hook
            #'meshmonitor-chat--update-mode-line nil t))

(defvar meshmonitor-chat--max-message-bytes 600
  "Maximum message size in bytes (3 parts x ~200 bytes).")

(defun meshmonitor-chat--input-byte-length ()
  "Return the byte length of the current input text."
  (if (and meshmonitor-chat--prompt-end
           (marker-position meshmonitor-chat--prompt-end))
      (string-bytes
       (buffer-substring-no-properties
        meshmonitor-chat--prompt-end (point-max)))
    0))

(defun meshmonitor-chat--mode-line-status ()
  "Return mode-line status string with connection and input size."
  (let* ((conn (if meshmonitor-chat--connected "[on]" "[off]"))
         (len (meshmonitor-chat--input-byte-length)))
    (if (> len 0)
        (let ((face (cond
                     ((> len meshmonitor-chat--max-message-bytes)
                      'error)
                     ((> len 200) 'warning)
                     (t nil))))
          (format "%s %s"
                  conn
                  (if face
                      (propertize (format "[%d/%d B]" len
                                         meshmonitor-chat--max-message-bytes)
                                 'face face)
                    (format "[%d B]" len))))
      conn)))

(defun meshmonitor-chat--update-mode-line ()
  "Force mode-line update when input changes."
  (force-mode-line-update))

(defun meshmonitor-chat--prompt-string ()
  "Return the prompt string for the current buffer."
  (let ((base (pcase meshmonitor-chat--target-type
                ('channel (format "#%s> "
                                  (meshmonitor-chat--channel-name
                                   meshmonitor-chat--target)))
                ('dm (format "%s> "
                             (meshmonitor-chat--node-name
                              meshmonitor-chat--target)))
                (_ "MeshMonitor> "))))
    (if meshmonitor-chat--reply-to
        (format "[reply %s] %s"
                (cdr meshmonitor-chat--reply-to) base)
      base)))

(defun meshmonitor-chat--setup-prompt ()
  "Insert the input prompt at the end of the current buffer."
  (goto-char (point-max))
  (let ((start (point))
        (txt (meshmonitor-chat--prompt-string)))
    (insert (propertize txt
                        'face 'meshmonitor-chat-prompt-face
                        'read-only t
                        'front-sticky t
                        'rear-nonsticky t))
    (set-marker meshmonitor-chat--prompt-start start)
    (set-marker meshmonitor-chat--prompt-end (point))))

(defun meshmonitor-chat--refresh-prompt ()
  "Refresh the prompt text, preserving input."
  (let ((inhibit-read-only t)
        (input (buffer-substring-no-properties
                meshmonitor-chat--prompt-end (point-max))))
    (save-excursion
      (delete-region meshmonitor-chat--prompt-start (point-max))
      (goto-char meshmonitor-chat--prompt-start)
      (let ((txt (meshmonitor-chat--prompt-string)))
        (insert (propertize txt
                            'face 'meshmonitor-chat-prompt-face
                            'read-only t
                            'front-sticky t
                            'rear-nonsticky t))
        (set-marker meshmonitor-chat--prompt-end (point)))
      (insert input))))

;;;; Message rendering

(defun meshmonitor-chat--insert-msg (buffer ts sender text
                                            &optional selfp sysp
                                            request-id)
  "Insert a chat message into BUFFER.
TS is the timestamp, SENDER the display name, TEXT the content.
SELFP non-nil marks the message as from the local node.
SYSP non-nil renders a system notification instead.
REQUEST-ID is stored as text property for reply support."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (at-end (>= (point) meshmonitor-chat--prompt-end)))
        (save-excursion
          (set-marker-insertion-type
           meshmonitor-chat--prompt-start t)
          (set-marker-insertion-type
           meshmonitor-chat--prompt-end t)
          (goto-char meshmonitor-chat--prompt-start)
          (insert
           (propertize
            (if sysp
                (format "*** %s\n" text)
              (concat
               (propertize
                (format "[%s] "
                        (if ts
                            (meshmonitor-chat--format-time ts)
                          "--:--"))
                'face 'meshmonitor-chat-timestamp-face)
               (propertize
                (format "<%s> " sender)
                'face (if selfp
                          'meshmonitor-chat-nick-self-face
                        'meshmonitor-chat-nick-other-face))
               text "\n"))
            'read-only t
            'rear-nonsticky t
            'front-sticky t
            'face (when sysp 'meshmonitor-chat-system-face)
            'meshmonitor-chat-msg-text text
            'meshmonitor-chat-request-id request-id
            'meshmonitor-chat-sender sender))
          (set-marker-insertion-type
           meshmonitor-chat--prompt-start nil)
          (set-marker-insertion-type
           meshmonitor-chat--prompt-end nil))
        (when at-end
          (goto-char meshmonitor-chat--prompt-end))))))

(defun meshmonitor-chat--insert-sent-msg (buffer text request-id)
  "Insert own sent message into BUFFER with pending delivery icon.
TEXT is the message, REQUEST-ID is used for delivery tracking."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (at-end (>= (point) meshmonitor-chat--prompt-end))
            (sender (meshmonitor-chat--node-name
                     (or meshmonitor-chat--my-node-id "me"))))
        (save-excursion
          (set-marker-insertion-type
           meshmonitor-chat--prompt-start t)
          (set-marker-insertion-type
           meshmonitor-chat--prompt-end t)
          (goto-char meshmonitor-chat--prompt-start)
          ;; Message text.
          (insert
             (propertize
              (concat
               (propertize
                (format "[%s] "
                        (format-time-string
                         meshmonitor-chat-timestamp-format))
                'face 'meshmonitor-chat-timestamp-face)
               (propertize (format "<%s> " sender)
                           'face 'meshmonitor-chat-nick-self-face)
               text " ")
              'read-only t 'rear-nonsticky t 'front-sticky t
              'meshmonitor-chat-msg-text text))
          ;; Delivery icon.
          (let ((icon-pos (point)))
            (insert (meshmonitor-chat--delivery-icon 'pending))
            (insert (propertize "\n" 'read-only t
                                'rear-nonsticky t))
            (when request-id
              (push (cons request-id (copy-marker icon-pos))
                    meshmonitor-chat--pending-deliveries)))
          (set-marker-insertion-type
           meshmonitor-chat--prompt-start nil)
          (set-marker-insertion-type
           meshmonitor-chat--prompt-end nil))
        (when at-end
          (goto-char meshmonitor-chat--prompt-end))))))

(defun meshmonitor-chat--is-self-p (msg)
  "Return non-nil if MSG is from the local node."
  (let ((from-id (alist-get 'fromNodeId msg))
        (from-num (alist-get 'fromNodeNum msg)))
    (or (and meshmonitor-chat--my-node-id from-id
             (equal from-id meshmonitor-chat--my-node-id))
        (and meshmonitor-chat--my-node-num from-num
             (equal from-num meshmonitor-chat--my-node-num)))))

(defun meshmonitor-chat--msg-delivery-state (msg)
  "Return delivery state symbol for MSG, or nil."
  (cond
   ((equal (alist-get 'ackFailed msg) 1) 'failed)
   ((alist-get 'deliveryState msg)
    (let ((ds (alist-get 'deliveryState msg)))
      (cond
       ((member ds '("confirmed" "delivered")) 'confirmed)
       ((member ds '("failed" "error")) 'failed)
       ((equal ds "pending") 'pending)
       (t nil))))
   (t nil)))

(defun meshmonitor-chat--render-messages (buffer messages)
  "Render MESSAGES into BUFFER with deduplication.
MESSAGES is a list of message alists from the API."
  (when (and (buffer-live-p buffer) messages)
    (let ((sorted (sort (copy-sequence messages)
                        (lambda (a b)
                          (< (meshmonitor-chat--parse-timestamp
                              (alist-get 'timestamp a))
                             (meshmonitor-chat--parse-timestamp
                              (alist-get 'timestamp b)))))))
      (dolist (msg sorted)
        (let ((id (alist-get 'id msg)))
          (unless (and id (with-current-buffer buffer
                            (gethash id meshmonitor-chat--seen-ids)))
            ;; Check delivery updates for pending sent messages.
            (meshmonitor-chat--check-delivery msg buffer)
            (let* ((from (or (alist-get 'fromNodeId msg)
                             (alist-get 'from msg)))
                   (sender (meshmonitor-chat--node-name from))
                   (text (or (alist-get 'text msg) ""))
                   (ts (alist-get 'timestamp msg))
                   (selfp (meshmonitor-chat--is-self-p msg))
                   (unix-ts (meshmonitor-chat--parse-timestamp ts))
                   (req-id (alist-get 'requestId msg))
                   (delivery (when selfp
                               (meshmonitor-chat--msg-delivery-state
                                msg))))
              ;; Skip if delivery check already handled it.
              (unless (and id (with-current-buffer buffer
                                (gethash id
                                         meshmonitor-chat--seen-ids)))
                (if (and selfp delivery)
                    ;; Self message with delivery state: use sent format.
                    (meshmonitor-chat--insert-sent-msg-with-state
                     buffer ts sender text delivery)
                  (meshmonitor-chat--insert-msg
                   buffer ts sender text selfp nil req-id)
                  ;; Notify for messages from others when not visible.
                  (unless (or selfp (get-buffer-window buffer))
                    (with-current-buffer buffer
                      (meshmonitor-chat--notify
                       sender text
                       meshmonitor-chat--target-type
                       meshmonitor-chat--target))))
                (when id
                  (with-current-buffer buffer
                    (puthash id t meshmonitor-chat--seen-ids)))
                (with-current-buffer buffer
                  (when (or (null meshmonitor-chat--last-timestamp)
                            (> unix-ts
                               meshmonitor-chat--last-timestamp))
                    (setq meshmonitor-chat--last-timestamp
                          unix-ts))))))))
      ;; Mark conversation as read when buffer is visible.
      (when (get-buffer-window buffer)
        (with-current-buffer buffer
          (let ((key (cons meshmonitor-chat--target-type
                          meshmonitor-chat--target)))
            (puthash key (or meshmonitor-chat--last-timestamp 0)
                     meshmonitor-chat--read-timestamps)))))))

(defun meshmonitor-chat--insert-sent-msg-with-state
    (buffer ts sender text state)
  "Insert a self message into BUFFER with delivery STATE icon.
TS is the timestamp, SENDER the name, TEXT the content."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (at-end (>= (point) meshmonitor-chat--prompt-end)))
        (save-excursion
          (set-marker-insertion-type
           meshmonitor-chat--prompt-start t)
          (set-marker-insertion-type
           meshmonitor-chat--prompt-end t)
          (goto-char meshmonitor-chat--prompt-start)
          (insert
           (propertize
            (concat
             (propertize
              (format "[%s] "
                      (if ts
                          (meshmonitor-chat--format-time ts)
                        "--:--"))
              'face 'meshmonitor-chat-timestamp-face)
             (propertize (format "<%s> " sender)
                         'face 'meshmonitor-chat-nick-self-face)
             text " ")
            'read-only t 'rear-nonsticky t 'front-sticky t
            'meshmonitor-chat-msg-text text))
          (insert (meshmonitor-chat--delivery-icon state))
          (insert (propertize "\n" 'read-only t 'rear-nonsticky t))
          (set-marker-insertion-type
           meshmonitor-chat--prompt-start nil)
          (set-marker-insertion-type
           meshmonitor-chat--prompt-end nil))
        (when at-end
          (goto-char meshmonitor-chat--prompt-end))))))

;;;; Input handling

(defun meshmonitor-chat-send-input ()
  "Send the text after the prompt as a message."
  (interactive)
  (if (< (point) meshmonitor-chat--prompt-end)
      (goto-char (point-max))
    (let ((input (buffer-substring-no-properties
                  meshmonitor-chat--prompt-end (point-max))))
      (when (string-blank-p input)
        (user-error "Empty message"))
      (ring-insert meshmonitor-chat--input-ring input)
      (setq meshmonitor-chat--input-ring-index 0)
      (let ((inhibit-read-only t))
        (delete-region meshmonitor-chat--prompt-end (point-max)))
      (meshmonitor-chat--send-text input))))

(defun meshmonitor-chat--send-text (text)
  "Send TEXT to the current buffer target."
  (unless meshmonitor-chat--connected
    (user-error "Not connected to MeshMonitor"))
  (let ((buf (current-buffer))
        (target meshmonitor-chat--target)
        (ttype meshmonitor-chat--target-type)
        (reply-id (car meshmonitor-chat--reply-to)))
    ;; Clear reply context after capturing it.
    (when meshmonitor-chat--reply-to
      (setq meshmonitor-chat--reply-to nil)
      (meshmonitor-chat--refresh-prompt))
    (let ((cb (lambda (result)
                (let ((status (if result (car result) 0))
                      (data (alist-get 'data (cdr result))))
                  (cond
                   ;; 201: sent directly.
                   ((and result (< status 400))
                    (let ((req-id (alist-get 'requestId data))
                          (parts (or (alist-get 'messageCount data)
                                     1)))
                      (meshmonitor-chat--insert-sent-msg
                       buf text req-id)
                      ;; Inform if message was split (202).
                      (when (> parts 1)
                        (meshmonitor-chat--insert-msg
                         buf nil nil
                         (format "Message split into %d parts"
                                 parts)
                         nil t))))
                   ;; 413: message too long.
                   ((and result (= status 413))
                    (meshmonitor-chat--insert-msg
                     buf nil nil
                     "Message too long (max ~600 bytes, 3 parts)"
                     nil t))
                   ;; 503: node not connected.
                   ((and result (= status 503))
                    (meshmonitor-chat--insert-msg
                     buf nil nil
                     "Meshtastic node not connected" nil t))
                   ;; Other errors.
                   (t
                    (meshmonitor-chat--insert-msg
                     buf nil nil
                     (format "Send failed (HTTP %s)"
                             (or status "timeout"))
                     nil t)))))))
      (pcase ttype
        ('channel
         (meshmonitor-chat--api-send text target nil
                                     reply-id cb))
        ('dm
         (meshmonitor-chat--api-send text nil target
                                     reply-id cb))
        (_ (user-error "No target set for this buffer"))))))

(defun meshmonitor-chat-previous-input ()
  "Replace current input with previous entry from history."
  (interactive)
  (when (> (ring-length meshmonitor-chat--input-ring) 0)
    (let ((inhibit-read-only t))
      (delete-region meshmonitor-chat--prompt-end (point-max))
      (insert (ring-ref meshmonitor-chat--input-ring
                        meshmonitor-chat--input-ring-index))
      (setq meshmonitor-chat--input-ring-index
            (mod (1+ meshmonitor-chat--input-ring-index)
                 (ring-length meshmonitor-chat--input-ring))))))

(defun meshmonitor-chat-next-input ()
  "Replace current input with next entry from history."
  (interactive)
  (when (> (ring-length meshmonitor-chat--input-ring) 0)
    (let ((inhibit-read-only t))
      (delete-region meshmonitor-chat--prompt-end (point-max))
      (setq meshmonitor-chat--input-ring-index
            (mod (1- meshmonitor-chat--input-ring-index)
                 (ring-length meshmonitor-chat--input-ring)))
      (insert (ring-ref meshmonitor-chat--input-ring
                        meshmonitor-chat--input-ring-index)))))

(defun meshmonitor-chat-resend ()
  "Resend the message at point.
Searches the current line for a sent message to resend."
  (interactive)
  (let ((text nil)
        (start (line-beginning-position))
        (end (line-end-position)))
    (save-excursion
      (goto-char start)
      (while (and (not text) (< (point) end))
        (setq text (get-text-property (point)
                                      'meshmonitor-chat-msg-text))
        (goto-char (or (next-single-property-change
                        (point) 'meshmonitor-chat-msg-text nil end)
                       end))))
    (if text
        (progn
          (goto-char meshmonitor-chat--prompt-end)
          (meshmonitor-chat--send-text text))
      (user-error "No sent message at point"))))

(defun meshmonitor-chat--get-msg-property-at-line (prop)
  "Get text property PROP from the current line."
  (let ((value nil)
        (start (line-beginning-position))
        (end (line-end-position)))
    (save-excursion
      (goto-char start)
      (while (and (not value) (< (point) end))
        (setq value (get-text-property (point) prop))
        (goto-char (or (next-single-property-change
                        (point) prop nil end)
                       end))))
    value))

(defun meshmonitor-chat-reply ()
  "Set reply context to the message at point.
The next sent message will be a reply to this one."
  (interactive)
  (let ((req-id (meshmonitor-chat--get-msg-property-at-line
                 'meshmonitor-chat-request-id))
        (sender (meshmonitor-chat--get-msg-property-at-line
                 'meshmonitor-chat-sender)))
    (if req-id
        (progn
          (setq meshmonitor-chat--reply-to (cons req-id sender))
          (meshmonitor-chat--refresh-prompt)
          (goto-char (point-max))
          (message "Replying to %s (C-c C-k to cancel)" sender))
      (user-error "No message at point"))))

(defun meshmonitor-chat-cancel-reply ()
  "Cancel the current reply context."
  (interactive)
  (setq meshmonitor-chat--reply-to nil)
  (meshmonitor-chat--refresh-prompt)
  (message "Reply cancelled"))

(defun meshmonitor-chat-react ()
  "React with an emoji to the message at point."
  (interactive)
  (let ((req-id (meshmonitor-chat--get-msg-property-at-line
                 'meshmonitor-chat-request-id)))
    (if req-id
        (let ((emoji (read-string "Emoji: ")))
          (when (not (string-empty-p emoji))
            (let ((meshmonitor-chat--reply-to
                   (cons req-id "react")))
              (meshmonitor-chat--send-text emoji))))
      (user-error "No message at point"))))

;;;; Buffer management

(defun meshmonitor-chat--buffer-name (ttype target)
  "Generate buffer name for target type TTYPE and TARGET."
  (pcase ttype
    ('channel (format "*MeshMonitor: #%s*"
                      (meshmonitor-chat--channel-name target)))
    ('dm (format "*MeshMonitor: DM %s*"
                 (meshmonitor-chat--node-name target)))))

(defun meshmonitor-chat--get-or-create-buffer (ttype target)
  "Get or create a chat buffer for TTYPE and TARGET."
  (let* ((name (meshmonitor-chat--buffer-name ttype target))
         (buf (get-buffer name)))
    (if (and buf (buffer-live-p buf))
        buf
      (setq buf (get-buffer-create name))
      (with-current-buffer buf
        (meshmonitor-chat-mode)
        (setq meshmonitor-chat--target target)
        (setq meshmonitor-chat--target-type ttype)
        (meshmonitor-chat--setup-prompt))
      (push (cons (cons ttype target) buf)
            meshmonitor-chat--chat-buffers)
      buf)))

;;;; Channel list mode

(defvar meshmonitor-chat-channel-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET")
                #'meshmonitor-chat-channel-list-open)
    (define-key map (kbd "g")
                #'meshmonitor-chat-channel-list-refresh)
    map)
  "Keymap for `meshmonitor-chat-channel-list-mode'.")

(define-derived-mode meshmonitor-chat-channel-list-mode
  tabulated-list-mode "MeshChannels"
  "Major mode for listing MeshMonitor channels."
  :group 'meshmonitor-chat
  (setq tabulated-list-format
        [("ID" 4 t)
         ("Name" 20 t)
         ("Role" 12 t)])
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(defun meshmonitor-chat-channel-list-open ()
  "Open the channel at point."
  (interactive)
  (let ((entry (tabulated-list-get-entry)))
    (when entry
      (meshmonitor-chat-open-channel
       (string-to-number (aref entry 0))))))

(defun meshmonitor-chat-channel-list-refresh ()
  "Refresh the channel list from the server."
  (interactive)
  (meshmonitor-chat--fetch-channels
   (lambda (_channels)
     (let ((buf (get-buffer "*MeshMonitor: Channels*")))
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (meshmonitor-chat--populate-channel-list)))))))

(defun meshmonitor-chat--populate-channel-list ()
  "Populate the current buffer with cached channel data."
  (let ((role-names '((0 . "Disabled")
                      (1 . "Primary")
                      (2 . "Secondary"))))
    (setq tabulated-list-entries
          (mapcar
           (lambda (ch)
             (let ((id (alist-get 'id ch))
                   (name (or (alist-get 'name ch) ""))
                   (role (or (alist-get 'role ch) 0)))
               (list id
                     (vector (number-to-string id)
                             name
                             (or (cdr (assq role role-names))
                                 (format "%d" role))))))
           (seq-filter
            (lambda (ch) (> (or (alist-get 'role ch) 0) 0))
            meshmonitor-chat--channels)))
    (tabulated-list-print t)))

;;;; DM list mode

(defvar meshmonitor-chat-dm-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET")
                #'meshmonitor-chat-dm-list-open)
    (define-key map (kbd "g")
                #'meshmonitor-chat-dm-list-refresh)
    map)
  "Keymap for `meshmonitor-chat-dm-list-mode'.")

(define-derived-mode meshmonitor-chat-dm-list-mode
  tabulated-list-mode "MeshDMs"
  "Major mode for listing MeshMonitor DM conversations."
  :group 'meshmonitor-chat
  (setq tabulated-list-format
        [("Name" 20 t)
         ("Node ID" 14 t)
         ("Last message" 40 nil)])
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(defun meshmonitor-chat-dm-list-open ()
  "Open DM chat with the node at point."
  (interactive)
  (let ((entry (tabulated-list-get-entry)))
    (when entry
      (meshmonitor-chat-open-dm (aref entry 1)))))

(defun meshmonitor-chat-dm-list-refresh ()
  "Refresh the DM conversation list from the server."
  (interactive)
  (meshmonitor-chat--fetch-dm-conversations
   (lambda (partners)
     (let ((buf (get-buffer "*MeshMonitor: Direct Messages*")))
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (meshmonitor-chat--populate-dm-list partners)))))))

(defun meshmonitor-chat--fetch-dm-conversations (callback)
  "Fetch DM conversations and call CALLBACK with partner alist.
Each element is (NODE-ID . LAST-MESSAGE-ALIST)."
  (meshmonitor-chat--api-messages
   `((limit . 200))
   (lambda (result)
     (let ((partners nil))
       (when result
         (let* ((msgs (alist-get 'data (cdr result)))
                (dm-msgs (seq-filter
                          (lambda (m)
                            (equal (alist-get 'channel m) -1))
                          msgs)))
           (setq partners
                 (meshmonitor-chat--extract-dm-partners
                  dm-msgs))))
       (funcall callback partners)))))

(defun meshmonitor-chat--extract-dm-partners (messages)
  "Extract unique DM conversation partners from MESSAGES.
Return alist of (NODE-ID . LAST-MESSAGE-ALIST)."
  (let ((partners (make-hash-table :test 'equal)))
    (dolist (msg messages)
      (let ((from (alist-get 'fromNodeId msg))
            (to (alist-get 'toNodeId msg))
            (ts (meshmonitor-chat--parse-timestamp
                 (alist-get 'timestamp msg))))
        (let ((partner
               (cond
                ((and meshmonitor-chat--my-node-id
                      (equal from meshmonitor-chat--my-node-id))
                 to)
                ((and meshmonitor-chat--my-node-id
                      (equal to meshmonitor-chat--my-node-id))
                 from)
                (t from))))
          (when (and partner
                     (not (equal partner "broadcast"))
                     (not (equal partner
                                 meshmonitor-chat--my-node-id)))
            (let ((existing (gethash partner partners)))
              (when (or (null existing)
                        (> ts (meshmonitor-chat--parse-timestamp
                               (alist-get 'timestamp existing))))
                (puthash partner msg partners)))))))
    (let ((result nil))
      (maphash (lambda (k v) (push (cons k v) result)) partners)
      result)))

(defun meshmonitor-chat--populate-dm-list (partners)
  "Populate the current buffer with DM PARTNERS alist."
  (setq tabulated-list-entries
        (mapcar
         (lambda (entry)
           (let* ((node-id (car entry))
                  (msg (cdr entry))
                  (name (meshmonitor-chat--node-name node-id))
                  (text (or (alist-get 'text msg) "")))
             (list node-id
                   (vector name
                           node-id
                           (truncate-string-to-width
                            text 40 nil nil "...")))))
         partners))
  (tabulated-list-print t))

;;;; Node list mode

(defvar meshmonitor-chat-node-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET")
                #'meshmonitor-chat-node-list-open)
    (define-key map (kbd "g")
                #'meshmonitor-chat-node-list-refresh)
    map)
  "Keymap for `meshmonitor-chat-node-list-mode'.")

(define-derived-mode meshmonitor-chat-node-list-mode
  tabulated-list-mode "MeshNodes"
  "Major mode for listing MeshMonitor nodes sorted by hops."
  :group 'meshmonitor-chat
  (setq tabulated-list-format
        [("Hops" 5 meshmonitor-chat--sort-by-hops)
         ("Name" 30 t)
         ("Node ID" 14 t)
         ("Last heard" 12 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key '("Hops"))
  (tabulated-list-init-header))

(defun meshmonitor-chat--sort-by-hops (a b)
  "Sort entries A and B by hop count numerically."
  (let ((ha (string-to-number (aref (cadr a) 0)))
        (hb (string-to-number (aref (cadr b) 0))))
    (< ha hb)))

(defun meshmonitor-chat-node-list-open ()
  "Open DM chat with the node at point."
  (interactive)
  (let ((entry (tabulated-list-get-entry)))
    (when entry
      (meshmonitor-chat-open-dm (aref entry 2)))))

(defun meshmonitor-chat-node-list-refresh ()
  "Refresh the node list from the server."
  (interactive)
  (meshmonitor-chat--fetch-nodes
   (lambda ()
     (let ((buf (get-buffer "*MeshMonitor: Nodes*")))
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (meshmonitor-chat--populate-node-list)))))))

(defun meshmonitor-chat--format-last-heard (ts)
  "Format last heard timestamp TS as relative time."
  (if (and ts (numberp ts) (> ts 0))
      (let* ((secs (- (float-time) (if (> ts 9999999999)
                                       (/ ts 1000) ts)))
             (mins (/ secs 60))
             (hours (/ mins 60))
             (days (/ hours 24)))
        (cond
         ((< mins 1) "now")
         ((< mins 60) (format "%dm" (truncate mins)))
         ((< hours 24) (format "%dh" (truncate hours)))
         (t (format "%dd" (truncate days)))))
    "?"))

(defun meshmonitor-chat--populate-node-list ()
  "Populate the current buffer with cached node data."
  (let ((entries nil))
    (maphash
     (lambda (key node)
       (when (string-prefix-p "!" key)
         (let ((hops (or (alist-get 'hopsAway node) 99))
               (name (or (alist-get 'longName node) ""))
               (last-heard (alist-get 'lastHeard node)))
           (push (list key
                       (vector (number-to-string hops)
                               name
                               key
                               (meshmonitor-chat--format-last-heard
                                last-heard)))
                 entries))))
     meshmonitor-chat--nodes)
    (setq tabulated-list-entries entries)
    (tabulated-list-print t)))

;;;; Unread messages mode

(defvar meshmonitor-chat-unread-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET")
                #'meshmonitor-chat-unread-list-open)
    (define-key map (kbd "g")
                #'meshmonitor-chat-unread-list-refresh)
    map)
  "Keymap for `meshmonitor-chat-unread-list-mode'.")

(define-derived-mode meshmonitor-chat-unread-list-mode
  tabulated-list-mode "MeshUnread"
  "Major mode for listing nodes with unread messages."
  :group 'meshmonitor-chat
  (setq tabulated-list-format
        [("Unread" 7 meshmonitor-chat--sort-by-unread)
         ("Name" 25 t)
         ("Node ID" 14 t)
         ("Last message" 40 nil)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key '("Unread" . t))
  (tabulated-list-init-header))

(defun meshmonitor-chat--sort-by-unread (a b)
  "Sort entries A and B by unread count numerically."
  (let ((ua (string-to-number (aref (cadr a) 0)))
        (ub (string-to-number (aref (cadr b) 0))))
    (< ua ub)))

(defun meshmonitor-chat-unread-list-open ()
  "Open DM chat with the node at point."
  (interactive)
  (let ((entry (tabulated-list-get-entry)))
    (when entry
      (meshmonitor-chat-open-dm (aref entry 2)))))

(defun meshmonitor-chat-unread-list-refresh ()
  "Refresh the unread messages list from the server."
  (interactive)
  (meshmonitor-chat--fetch-unread
   (lambda (unread)
     (let ((buf (get-buffer "*MeshMonitor: Unread*")))
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (meshmonitor-chat--populate-unread-list unread)))))))

(defun meshmonitor-chat--fetch-unread (callback)
  "Fetch messages and find unread conversations.
Call CALLBACK with alist of (NODE-ID . (COUNT . LAST-MSG))."
  (meshmonitor-chat--api-messages
   `((limit . 200))
   (lambda (result)
     (let ((unread nil))
       (when result
         (let ((msgs (alist-get 'data (cdr result))))
           (when msgs
             (let ((by-node (make-hash-table :test 'equal)))
               ;; Group messages by conversation partner.
               (dolist (msg msgs)
                 (let* ((from (alist-get 'fromNodeId msg))
                        (ts (meshmonitor-chat--parse-timestamp
                             (alist-get 'timestamp msg)))
                        (channel (alist-get 'channel msg))
                        (is-dm (equal channel -1))
                        (is-self (meshmonitor-chat--is-self-p msg)))
                   ;; Only count DMs from others.
                   (when (and is-dm (not is-self) from)
                     (let* ((read-key (cons 'dm from))
                            (read-ts (or (gethash read-key
                                                  meshmonitor-chat--read-timestamps)
                                         0)))
                       (when (> ts read-ts)
                         (let ((entry (gethash from by-node)))
                           (if entry
                               (progn
                                 (cl-incf (car entry))
                                 (when (> ts
                                          (meshmonitor-chat--parse-timestamp
                                           (alist-get 'timestamp
                                                      (cdr entry))))
                                   (setcdr entry msg)))
                             (puthash from (cons 1 msg)
                                      by-node))))))))
               ;; Convert to alist.
               (maphash (lambda (k v)
                          (push (list k (car v) (cdr v)) unread))
                        by-node)))))
       (funcall callback unread)))))

(defun meshmonitor-chat--populate-unread-list (unread)
  "Populate current buffer with UNREAD conversation data.
Each element of UNREAD is (NODE-ID COUNT LAST-MSG)."
  (setq tabulated-list-entries
        (mapcar
         (lambda (entry)
           (let* ((node-id (nth 0 entry))
                  (count (nth 1 entry))
                  (msg (nth 2 entry))
                  (name (meshmonitor-chat--node-name node-id))
                  (text (or (alist-get 'text msg) "")))
             (list node-id
                   (vector (number-to-string count)
                           name
                           node-id
                           (truncate-string-to-width
                            text 40 nil nil "...")))))
         unread))
  (tabulated-list-print t))

;;;; Open chat buffers

(defun meshmonitor-chat-open-channel (channel-id)
  "Open a chat buffer for CHANNEL-ID and load message history."
  (meshmonitor-chat--ensure-connected)
  (let ((buf (meshmonitor-chat--get-or-create-buffer
              'channel channel-id)))
    (switch-to-buffer buf)
    (meshmonitor-chat--api-messages
     `((channel . ,channel-id)
       (limit . ,meshmonitor-chat-message-limit))
     (lambda (result)
       (when result
         (let ((msgs (alist-get 'data (cdr result))))
           (when msgs
             (meshmonitor-chat--render-messages buf msgs))))))))

(defun meshmonitor-chat-open-dm (node-id)
  "Open a DM chat buffer with NODE-ID and load history."
  (meshmonitor-chat--ensure-connected)
  (let ((buf (meshmonitor-chat--get-or-create-buffer 'dm node-id)))
    (switch-to-buffer buf)
    (let ((all-messages nil)
          (pending 2))
      (let ((handler
             (lambda (result)
               (when result
                 (let ((msgs (alist-get 'data (cdr result))))
                   (when msgs
                     (setq all-messages
                           (append msgs all-messages)))))
               (setq pending (1- pending))
               (when (zerop pending)
                 (meshmonitor-chat--render-messages
                  buf all-messages)))))
        (meshmonitor-chat--api-messages
         `((toNodeId . ,node-id)
           (limit . ,meshmonitor-chat-message-limit))
         handler)
        (meshmonitor-chat--api-messages
         `((fromNodeId . ,node-id)
           (limit . ,meshmonitor-chat-message-limit))
         handler)))))

;;;; Polling

(defun meshmonitor-chat--start-polling ()
  "Start the periodic message polling timer."
  (meshmonitor-chat--stop-polling)
  (setq meshmonitor-chat--poll-timer
        (run-with-timer
         meshmonitor-chat-poll-interval
         meshmonitor-chat-poll-interval
         #'meshmonitor-chat--poll)))

(defun meshmonitor-chat--stop-polling ()
  "Stop the periodic message polling timer."
  (when meshmonitor-chat--poll-timer
    (cancel-timer meshmonitor-chat--poll-timer)
    (setq meshmonitor-chat--poll-timer nil)))

(defun meshmonitor-chat--poll ()
  "Poll for new messages in all open chat buffers."
  (when meshmonitor-chat--connected
    ;; Clean dead buffers.
    (setq meshmonitor-chat--chat-buffers
          (seq-filter (lambda (e) (buffer-live-p (cdr e)))
                      meshmonitor-chat--chat-buffers))
    (dolist (entry meshmonitor-chat--chat-buffers)
      (let* ((key (car entry))
             (buf (cdr entry))
             (ttype (car key))
             (target (cdr key))
             (since (with-current-buffer buf
                      meshmonitor-chat--last-timestamp)))
        (pcase ttype
          ('channel
           (let ((params `((channel . ,target) (limit . 20))))
             (when since
               (push `(since . ,(1+ since)) params))
             (meshmonitor-chat--api-messages
              params
              (lambda (result)
                (when result
                  (let ((msgs (alist-get 'data (cdr result))))
                    (when msgs
                      (meshmonitor-chat--render-messages
                       buf msgs))))))))
          ('dm
           (let ((params `((fromNodeId . ,target) (limit . 20))))
             (when since
               (push `(since . ,(1+ since)) params))
             (meshmonitor-chat--api-messages
              params
              (lambda (result)
                (when result
                  (let ((msgs (alist-get 'data (cdr result))))
                    (when msgs
                      (meshmonitor-chat--render-messages
                       buf msgs)))))))))))))

;;;; Notifications

(defun meshmonitor-chat--notify (sender text target-type target)
  "Show desktop notification for a message from SENDER.
TEXT is the message content, TARGET-TYPE and TARGET identify the chat."
  (when meshmonitor-chat-notify
    (let ((title (pcase target-type
                   ('channel (format "#%s"
                                     (meshmonitor-chat--channel-name
                                      target)))
                   ('dm sender)
                   (_ "MeshMonitor")))
          (body (truncate-string-to-width
                 (format "%s: %s" sender text) 100 nil nil "...")))
      (notifications-notify
       :title title
       :body body
       :app-name "MeshMonitor"
       :category "im.received"
       :urgency 'normal))))

;;;; Cleanup

;;;###autoload
(defun meshmonitor-chat-disconnect ()
  "Disconnect from MeshMonitor and clean up state."
  (interactive)
  (meshmonitor-chat--stop-polling)
  (setq meshmonitor-chat--connected nil
        meshmonitor-chat--auth-token nil
        meshmonitor-chat--base-url nil
        meshmonitor-chat--my-node-id nil
        meshmonitor-chat--my-node-num nil
        meshmonitor-chat--channels nil
        meshmonitor-chat--chat-buffers nil)
  (clrhash meshmonitor-chat--nodes)
  (clrhash meshmonitor-chat--read-timestamps)
  (message "MeshMonitor: disconnected"))

;;;; Entry points

;;;###autoload
(defun meshmonitor-chat-channels ()
  "Show the MeshMonitor channel list."
  (interactive)
  (meshmonitor-chat--ensure-connected)
  (let ((buf (get-buffer-create "*MeshMonitor: Channels*")))
    (with-current-buffer buf
      (unless (eq major-mode 'meshmonitor-chat-channel-list-mode)
        (meshmonitor-chat-channel-list-mode)))
    (switch-to-buffer buf)
    (meshmonitor-chat--fetch-channels
     (lambda (_channels)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (meshmonitor-chat--populate-channel-list)))))))

;;;###autoload
(defun meshmonitor-chat-direct-messages ()
  "Show the MeshMonitor DM conversation list."
  (interactive)
  (meshmonitor-chat--ensure-connected)
  (let ((buf (get-buffer-create "*MeshMonitor: Direct Messages*")))
    (with-current-buffer buf
      (unless (eq major-mode 'meshmonitor-chat-dm-list-mode)
        (meshmonitor-chat-dm-list-mode)))
    (switch-to-buffer buf)
    (meshmonitor-chat--fetch-dm-conversations
     (lambda (partners)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (meshmonitor-chat--populate-dm-list partners)))))))

;;;###autoload
(defun meshmonitor-chat-nodes ()
  "Show all MeshMonitor nodes sorted by hop count."
  (interactive)
  (meshmonitor-chat--ensure-connected)
  (let ((buf (get-buffer-create "*MeshMonitor: Nodes*")))
    (with-current-buffer buf
      (unless (eq major-mode 'meshmonitor-chat-node-list-mode)
        (meshmonitor-chat-node-list-mode)))
    (switch-to-buffer buf)
    (meshmonitor-chat--fetch-nodes
     (lambda ()
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (meshmonitor-chat--populate-node-list)))))))

;;;###autoload
(defun meshmonitor-chat-unread ()
  "Show nodes with unread direct messages."
  (interactive)
  (meshmonitor-chat--ensure-connected)
  (let ((buf (get-buffer-create "*MeshMonitor: Unread*")))
    (with-current-buffer buf
      (unless (eq major-mode 'meshmonitor-chat-unread-list-mode)
        (meshmonitor-chat-unread-list-mode)))
    (switch-to-buffer buf)
    (meshmonitor-chat--fetch-unread
     (lambda (unread)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (meshmonitor-chat--populate-unread-list unread)))))))

(provide 'meshmonitor-chat)
;;; meshmonitor-chat.el ends here
