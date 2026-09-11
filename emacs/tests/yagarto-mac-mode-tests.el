;;; yagarto-mac-mode-tests.el --- Tests for YAGARTO Mac mode -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Batch ERT coverage for `yagarto-mac-mode'.  External programs and GDB are
;; stubbed except for one short-lived process used to verify cleanup.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'asm-mode)
(require 'compile)
(require 'json)
(require 'yagarto-mac-mode)

(defconst yagarto-mac-test--repository-root
  (expand-file-name "../.." (file-name-directory
                              (or load-file-name buffer-file-name))))

(defun yagarto-mac-test--write-config (root profile &optional entry output)
  "Write a schema-1 test configuration under ROOT for PROFILE."
  (with-temp-file (expand-file-name "yagarto.json" root)
    (insert (json-encode
             `((schemaVersion . 1)
               (profile . ,profile)
               (entry . ,(or entry "start"))
               (sources . ["课程 示例.s"])
               (outputName . ,(or output "演示 固件")))))
    (insert "\n")))

(defun yagarto-mac-test--project (&optional profile)
  "Create and return a temporary project using PROFILE."
  (let ((root (make-temp-file "yagarto 中文 项目 " t)))
    (yagarto-mac-test--write-config root (or profile "arm7tdmi"))
    (with-temp-file (expand-file-name "课程 示例.s" root)
      (insert ".text\n.global start\nstart:\n    b .\n"))
    root))

(defun yagarto-mac-test--debug-json (&optional warnings)
  "Return a valid debug plan JSON string containing WARNINGS."
  (json-encode
   `((profile . "arm7tdmi")
     (backend . "qemu-arm926-compatible")
     (gdbExecutable . "/opt/工具 套件/arm-none-eabi-gdb")
     (gdbArguments . ["-q" "-nx" "-ex" "file \"/tmp/中文 项目/演示.elf\""
                      "-ex" "tbreak start" "-ex" "continue"])
     (initCommands . ["file \"/tmp/中文 项目/演示.elf\""
                      "tbreak start" "continue"])
     (warnings . ,(vconcat warnings))
     (elf . "/tmp/中文 项目/演示.elf")
     (projectDirectory . "/tmp/中文 项目"))))

(defun yagarto-mac-test--debug-json-with-arrays
    (gdb-arguments init-commands warnings)
  "Return debug JSON using raw array values supplied by the caller."
  (json-encode
   `((profile . "arm7tdmi")
     (backend . "gdb-simulator")
     (gdbExecutable . "/tmp/中文 工具/fake-gdb")
     (gdbArguments . ,gdb-arguments)
     (initCommands . ,init-commands)
     (warnings . ,warnings)
     (elf . "/tmp/中文 项目/演示.elf")
     (projectDirectory . "/tmp/中文 项目"))))

(defun yagarto-mac-test--user-error-message (function)
  "Call FUNCTION and return its `user-error' message."
  (condition-case error-data
      (progn
        (funcall function)
        (ert-fail "应触发 user-error"))
    (user-error (error-message-string error-data))))

(ert-deftest yagarto-mac-package-has-license-and-lexical-header ()
  (let ((source (expand-file-name "emacs/yagarto-mac-mode.el"
                                  yagarto-mac-test--repository-root)))
    (with-temp-buffer
      (insert-file-contents source)
      (goto-char (point-min))
      (should (looking-at-p ";;; yagarto-mac-mode.el .*lexical-binding: t"))
      (should (search-forward "SPDX-License-Identifier: GPL-3.0-or-later" nil t))
      (should (search-forward ";;;###autoload" nil t)))))

(ert-deftest yagarto-mac-package-loads-with-supported-custom-options ()
  (should (featurep 'yagarto-mac-mode))
  (should (equal yagarto-mac-command "yagarto-mac"))
  (should (equal yagarto-mac-profiles
                 '("arm7tdmi" "cortex-m4" "stm32f4-discovery")))
  (should (equal yagarto-mac-project-file "yagarto.json"))
  (dolist (command '(yagarto-mac-select-profile
                     yagarto-mac-build
                     yagarto-mac-run
                     yagarto-mac-debug
                     yagarto-mac-disassemble
                     yagarto-mac-memory
                     yagarto-mac-refresh-profile
                     yagarto-mac-stop))
    (should (commandp command))))

(ert-deftest yagarto-mac-mode-has-fixed-key-bindings ()
  (with-temp-buffer
    (asm-mode)
    (yagarto-mac-mode 1)
    (dolist (binding '(("C-c C-p" . yagarto-mac-select-profile)
                       ("C-c C-b" . yagarto-mac-build)
                       ("C-c C-r" . yagarto-mac-run)
                       ("C-c C-d" . yagarto-mac-debug)
                       ("C-c C-i" . yagarto-mac-disassemble)
                       ("C-c C-m" . yagarto-mac-memory)))
      (should (eq (lookup-key yagarto-mac-mode-map (kbd (car binding)))
                  (cdr binding))))))

(ert-deftest yagarto-mac-mode-shows-clear-no-project-state ()
  (let ((default-directory (file-name-as-directory
                            (make-temp-file "yagarto-no-project-" t))))
    (unwind-protect
        (with-temp-buffer
          (asm-mode)
          (yagarto-mac-mode 1)
          (should (string-match-p "YAG\\[无项目\\]"
                                  (yagarto-mac--mode-line))))
      (delete-directory default-directory t))))

(ert-deftest yagarto-mac-finds-project-upward-from-chinese-space-path ()
  (let* ((root (yagarto-mac-test--project))
         (nested (expand-file-name "源代码/含 空格" root))
         (source (expand-file-name "子程序.s" nested)))
    (unwind-protect
        (progn
          (make-directory nested t)
          (with-temp-file source (insert ".text\n"))
          (with-temp-buffer
            (setq buffer-file-name source
                  default-directory (file-name-as-directory nested))
            (should (equal (file-name-as-directory root)
                           (yagarto-mac--project-root)))))
      (delete-directory root t))))

(ert-deftest yagarto-mac-reads-config-and-refreshes-mode-line-after-change ()
  (let* ((root (yagarto-mac-test--project "arm7tdmi"))
         (source (expand-file-name "课程 示例.s" root))
         (config (expand-file-name "yagarto.json" root)))
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name source
                default-directory (file-name-as-directory root))
          (asm-mode)
          (yagarto-mac-mode 1)
          (should (string-match-p "YAG\\[ARM7\\]" (yagarto-mac--mode-line)))
          (yagarto-mac-test--write-config root "stm32f4-discovery" "main" "灯 固件")
          (set-file-times config (time-add (current-time) 2))
          (should (string-match-p "YAG\\[STM32\\]" (yagarto-mac--mode-line))))
      (delete-directory root t))))

(ert-deftest yagarto-mac-refresh-reports-corrupted-json-in-chinese ()
  (let* ((root (yagarto-mac-test--project))
         (source (expand-file-name "课程 示例.s" root)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "yagarto.json" root)
            (insert "{broken json"))
          (with-temp-buffer
            (setq buffer-file-name source
                  default-directory (file-name-as-directory root))
            (let ((message (yagarto-mac-test--user-error-message
                            #'yagarto-mac-refresh-profile)))
              (should (string-match-p "配置.*JSON\\|JSON.*配置" message)))))
      (delete-directory root t))))

(ert-deftest yagarto-mac-config-preserves-cli-empty-entry-default-contract ()
  (let ((root (yagarto-mac-test--project)))
    (unwind-protect
        (progn
          (yagarto-mac-test--write-config root "arm7tdmi" "" "blank-entry")
          (let ((configuration
                 (yagarto-mac--read-configuration
                  (file-name-as-directory root))))
            (should (equal (plist-get configuration :entry) ""))
            (should (equal (plist-get configuration :profile) "arm7tdmi"))))
      (delete-directory root t))))

(ert-deftest yagarto-mac-select-profile-passes-literal-argv ()
  (let* ((root (yagarto-mac-test--project))
         (source (expand-file-name "课程 示例.s" root))
         (yagarto-mac-command '("/opt/YAG 工具/yagarto-mac" "--trace-prefix"))
         seen)
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name source
                default-directory (file-name-as-directory root))
          (cl-letf (((symbol-function 'process-file)
                     (lambda (program _in destination _display &rest arguments)
                       (setq seen (list program arguments default-directory destination))
                       (insert "已设置\n")
                       0))
                    ((symbol-function 'yagarto-mac--refresh-project-buffers)
                     (lambda (_root) nil)))
            (yagarto-mac-select-profile "cortex-m4"))
          (should (equal (nth 0 seen) "/opt/YAG 工具/yagarto-mac"))
          (should (equal (nth 1 seen)
                         '("--trace-prefix" "profile" "set" "cortex-m4"
                           "--format" "text")))
          (should (equal (nth 2 seen) (file-name-as-directory root)))
          (should (eq (car (nth 3 seen)) t))
          (should (stringp (cadr (nth 3 seen)))))
      (delete-directory root t))))

(ert-deftest yagarto-mac-build-uses-quoted-command-and-project-directory ()
  (let* ((root (yagarto-mac-test--project))
         (source (expand-file-name "课程 示例.s" root))
         (yagarto-mac-command "/opt/YAG 工具/yagarto-mac")
         captured)
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name source
                default-directory (file-name-as-directory root))
          (cl-letf (((symbol-function 'compilation-start)
                     (lambda (command &optional mode name-function &rest _ignored)
                       (setq captured
                             (list command mode default-directory
                                   (and name-function (funcall name-function "build"))))
                       (get-buffer-create " *yagarto-build-test*"))))
            (yagarto-mac-build))
          (should (equal (nth 0 captured)
                         (mapconcat #'shell-quote-argument
                                    '("/opt/YAG 工具/yagarto-mac"
                                      "build" "--format" "text")
                                    " ")))
          (should (eq (nth 1 captured) 'yagarto-mac-compilation-mode))
          (should (equal (nth 2 captured) (file-name-as-directory root)))
          (should (string-match-p "yagarto-mac build" (nth 3 captured))))
      (kill-buffer " *yagarto-build-test*")
      (delete-directory root t))))

(ert-deftest yagarto-mac-compilation-regexp-is-buffer-local ()
  (let ((global-rules compilation-error-regexp-alist-alist)
        (global-active compilation-error-regexp-alist))
    (with-temp-buffer
      (yagarto-mac-compilation-mode)
      (should (local-variable-p 'compilation-error-regexp-alist-alist))
      (should (assq 'yagarto-mac-gnu compilation-error-regexp-alist-alist))
      (should (memq 'yagarto-mac-gnu compilation-error-regexp-alist)))
    (should (eq global-rules compilation-error-regexp-alist-alist))
    (should (eq global-active compilation-error-regexp-alist))))

(ert-deftest yagarto-mac-compilation-makes-gnu-source-error-clickable ()
  (let* ((root (yagarto-mac-test--project))
         (source (expand-file-name "课程 示例.s" root))
         found)
    (unwind-protect
        (with-temp-buffer
          (setq default-directory (file-name-as-directory root))
          (yagarto-mac-compilation-mode)
          (let ((inhibit-read-only t))
            (insert (format "%s:3:5: Error: bad instruction\n" source))
            (compilation--parse-region (point-min) (point-max)))
          (let ((position (point-min)))
            (while (and (< position (point-max)) (not found))
              (setq found (get-text-property position 'compilation-message)
                    position (next-single-property-change
                              position 'compilation-message nil (point-max)))))
          (should found))
      (delete-directory root t))))

(ert-deftest yagarto-mac-run-uses-comint-with-text-argv-and-visible-buffer ()
  (let* ((root (yagarto-mac-test--project))
         (source (expand-file-name "课程 示例.s" root))
         (yagarto-mac-command '("/opt/YAG 工具/yagarto-mac" "--prefix"))
         captured shown created)
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name source
                default-directory (file-name-as-directory root))
          (cl-letf (((symbol-function 'make-comint-in-buffer)
                     (lambda (name buffer program startfile &rest switches)
                       (setq captured (list name buffer program startfile switches
                                            default-directory)
                             created buffer)
                       buffer))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _ignored) (setq shown buffer))))
            (yagarto-mac-run))
          (should (equal (nth 2 captured) "/opt/YAG 工具/yagarto-mac"))
          (should-not (nth 3 captured))
          (should (equal (nth 4 captured)
                         '("--prefix" "run" "--format" "text")))
          (should-not (member "json" (nth 4 captured)))
          (should (equal (nth 5 captured) (file-name-as-directory root)))
          (should (eq shown created)))
      (when (buffer-live-p created) (kill-buffer created))
      (delete-directory root t))))

(ert-deftest yagarto-mac-debug-strictly-parses-current-launch-plan-schema ()
  (let ((plan (yagarto-mac--parse-debug-plan
               (yagarto-mac-test--debug-json nil))))
    (should (equal (plist-get plan :profile) "arm7tdmi"))
    (should (equal (plist-get plan :backend) "qemu-arm926-compatible"))
    (should (equal (plist-get plan :gdb-executable)
                   "/opt/工具 套件/arm-none-eabi-gdb"))
    (should (equal (car (plist-get plan :gdb-arguments)) "-q"))
    (should (equal (plist-get plan :warnings) nil))
    (should (equal (plist-get plan :project-directory) "/tmp/中文 项目"))))

(ert-deftest yagarto-mac-debug-rejects-missing-or-wrong-typed-plan-fields ()
  (let ((missing (json-encode
                  '((profile . "arm7tdmi")
                    (backend . "gdb-simulator")
                    (gdbExecutable . "/bin/gdb")
                    (gdbArguments . [])
                    (initCommands . [])
                    (elf . "/tmp/a.elf")
                    (projectDirectory . "/tmp"))))
        (wrong-type (json-encode
                     '((profile . "arm7tdmi")
                       (backend . "gdb-simulator")
                       (gdbExecutable . "/bin/gdb")
                       (gdbArguments . 42)
                       (initCommands . [])
                       (warnings . [])
                       (elf . "/tmp/a.elf")
                       (projectDirectory . "/tmp")))))
    (should-error (yagarto-mac--parse-debug-plan missing) :type 'user-error)
    (should-error (yagarto-mac--parse-debug-plan wrong-type) :type 'user-error)))

(ert-deftest yagarto-mac-debug-distinguishes-null-from-empty-arrays ()
  (should-not (eq yagarto-mac--json-null nil))
  (let ((empty-plan
         (yagarto-mac--parse-debug-plan
          (yagarto-mac-test--debug-json-with-arrays [] [] []))))
    (should-not (plist-get empty-plan :gdb-arguments))
    (should-not (plist-get empty-plan :init-commands))
    (should-not (plist-get empty-plan :warnings)))
  (dolist (values '((nil [] []) ([] nil []) ([] [] nil)))
    (should-error
     (yagarto-mac--parse-debug-plan
      (apply #'yagarto-mac-test--debug-json-with-arrays values))
     :type 'user-error))
  (dolist (values '(([nil] [] []) ([] [nil] []) ([] [] [nil])))
    (should-error
     (yagarto-mac--parse-debug-plan
      (apply #'yagarto-mac-test--debug-json-with-arrays values))
     :type 'user-error)))

(ert-deftest yagarto-mac-debug-rejects-trailing-json-content ()
  (let ((json (yagarto-mac-test--debug-json nil)))
    (should (yagarto-mac--parse-debug-plan (concat json " \t\r\n")))
    (should-error (yagarto-mac--parse-debug-plan (concat json " garbage"))
                  :type 'user-error)
    (should-error (yagarto-mac--parse-debug-plan (concat json " {}"))
                  :type 'user-error)))

(ert-deftest yagarto-mac-gdb-command-normalizes-ex-options-and-round-trips ()
  (let* ((file-command
          "file \"/tmp/中文 路径/a\\\\b \\\"quoted\\\".elf\"")
         (set-command
          "set substitute-path \"C:\\\\课程 源码\" \"/tmp/新 路径\"")
         (plan (list :gdb-executable "/tmp/工具 \\\"目录/fake\\\\gdb"
                     :gdb-arguments
                     (list "-q" "-nx"
                           "-ex" file-command
                           (concat "-ex=" set-command)
                           "-ex" "tbreak 课程入口")
                     :init-commands '("DO NOT EXECUTE")))
         (expected (list "/tmp/工具 \\\"目录/fake\\\\gdb"
                         "-i=mi" "-q" "-nx"
                         (concat "-ex=" file-command)
                         (concat "-ex=" set-command)
                         "-ex=tbreak 课程入口"))
         (command (yagarto-mac--gdb-command plan)))
    (should (equal (split-string-and-unquote command) expected))
    (should-not (string-match-p "DO NOT EXECUTE" command))))

(ert-deftest yagarto-mac-gdb-command-rejects-isolated-ex-option ()
  (should-error
   (yagarto-mac--gdb-command
    (list :gdb-executable "/tmp/fake-gdb"
          :gdb-arguments '("-q" "-ex")
          :init-commands nil))
   :type 'user-error))

(ert-deftest yagarto-mac-debug-runs-dry-plan-in-gdb-mi-many-windows-after-warning ()
  (let* ((root (yagarto-mac-test--project))
         (source (expand-file-name "课程 示例.s" root))
         (warning "ARM926 是 ARM7TDMI 兼容超集，非精确模型")
         (json (yagarto-mac-test--debug-json (list warning)))
         (yagarto-mac-command '("/opt/YAG 工具/yagarto-mac" "--prefix"))
         process-call gdb-command many-windows events)
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name source
                default-directory (file-name-as-directory root))
          (let ((gdb-many-windows nil))
            (cl-letf (((symbol-function 'process-file)
                       (lambda (program _in destination _display &rest arguments)
                         (setq process-call
                               (list program arguments default-directory destination))
                         (insert json)
                         0))
                      ((symbol-function 'display-warning)
                       (lambda (_type message &optional _level _buffer-name)
                         (push (list 'warning message) events)))
                      ((symbol-function 'gdb)
                       (lambda (command)
                         (push '(gdb) events)
                         (setq gdb-command command
                               many-windows gdb-many-windows))))
              (yagarto-mac-debug)))
          (should (equal (nth 0 process-call) "/opt/YAG 工具/yagarto-mac"))
          (should (equal (nth 1 process-call)
                         '("--prefix" "debug" "--dry-run" "--format" "json")))
          (should (equal (nth 2 process-call) (file-name-as-directory root)))
          (should (eq (car (nth 3 process-call)) t))
          (should (stringp (cadr (nth 3 process-call))))
          (should many-windows)
          (should
           (equal
            (split-string-and-unquote gdb-command)
            '("/opt/工具 套件/arm-none-eabi-gdb"
              "-i=mi" "-q" "-nx"
              "-ex=file \"/tmp/中文 项目/演示.elf\""
              "-ex=tbreak start" "-ex=continue")))
          (should (equal (mapcar #'car (nreverse events)) '(warning gdb))))
      (delete-directory root t))))

(ert-deftest yagarto-mac-gdb-command-survives-real-gud-common-init ()
  (skip-unless (file-executable-p "/bin/sh"))
  (let* ((root (make-temp-file "yagarto GUD 中文 " t))
         (fake-gdb (expand-file-name "fake \\\"gdb\\\\工具" root))
         (argument-log (expand-file-name "收到 argv.txt" root))
         (file-command
          "file \"/tmp/中文 路径/a\\\\b \\\"quoted\\\".elf\"")
         (set-command
          "set substitute-path \"C:\\\\课程\" \"/tmp/新 路径\"")
         (plan (list :gdb-executable fake-gdb
                     :gdb-arguments
                     (list "-q" "-nx" "-ex" file-command
                           "-ex" set-command "-ex=tbreak 课程入口")
                     :init-commands '("DO NOT EXECUTE")))
         (expected (list "-i=mi" "-q" "-nx"
                         (concat "-ex=" file-command)
                         (concat "-ex=" set-command)
                         "-ex=tbreak 课程入口"))
         (buffers-before (buffer-list))
         debugger-buffer debugger-process actual)
    (unwind-protect
        (progn
          (with-temp-file fake-gdb
            (insert "#!/bin/sh\n"
                    "printf '%s\\n' \"$@\" >\"$YAGARTO_FAKE_GDB_ARGS\"\n"
                    "printf '%s\\n' '(gdb)'\n"
                    "sleep 0.2\n"))
          (set-file-modes fake-gdb #o700)
          (let ((process-environment (copy-sequence process-environment))
                (default-directory (file-name-as-directory root)))
            (setenv "YAGARTO_FAKE_GDB_ARGS" argument-log)
            (condition-case error-data
                (save-window-excursion
                  (gud-common-init (yagarto-mac--gdb-command plan)
                                   nil #'identity)
                  (setq debugger-buffer (current-buffer)
                        debugger-process (get-buffer-process
                                          debugger-buffer)))
              (end-of-file
               (ert-fail (format "GUD command line raised end-of-file: %S"
                                 error-data))))
            (when debugger-process
              (set-process-query-on-exit-flag debugger-process nil))
            (let ((deadline (+ (float-time) 1.0)))
              (while (and (not (file-exists-p argument-log))
                          (< (float-time) deadline))
                (accept-process-output debugger-process 0.05)))
            (should (file-exists-p argument-log))
            (with-temp-buffer
              (let ((coding-system-for-read 'utf-8-unix))
                (insert-file-contents argument-log))
              (setq actual (split-string (buffer-string) "\n" t)))
            (should (equal actual expected))))
      (when debugger-process
        (set-process-query-on-exit-flag debugger-process nil)
        (when (process-live-p debugger-process)
          (delete-process debugger-process)))
      (dolist (buffer (buffer-list))
        (when (and (not (memq buffer buffers-before))
                   (buffer-live-p buffer))
          (with-current-buffer buffer
            (when-let ((process (get-buffer-process buffer)))
              (set-process-query-on-exit-flag process nil))
            (let ((kill-buffer-query-functions nil))
              (kill-buffer buffer)))))
      (delete-directory root t))))

(ert-deftest yagarto-mac-debug-keeps-wrapper-stderr-out-of-success-json ()
  (let* ((root (yagarto-mac-test--project))
         (source (expand-file-name "课程 示例.s" root))
         (json (yagarto-mac-test--debug-json nil))
         launched)
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name source
                default-directory (file-name-as-directory root))
          (cl-letf (((symbol-function 'process-file)
                     (lambda (_program _in destination _display &rest _arguments)
                       (insert json)
                       (with-temp-file (cadr destination)
                         (insert "wrapper build progress\n"))
                       0))
                    ((symbol-function 'gdb)
                     (lambda (_command) (setq launched t))))
            (yagarto-mac-debug))
          (should launched))
      (delete-directory root t))))

(ert-deftest yagarto-mac-debug-reports-malformed-json-and-missing-cli ()
  (let* ((root (yagarto-mac-test--project))
         (source (expand-file-name "课程 示例.s" root)))
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name source
                default-directory (file-name-as-directory root))
          (cl-letf (((symbol-function 'process-file)
                     (lambda (&rest _arguments) (insert "{bad") 0)))
            (let ((message (yagarto-mac-test--user-error-message
                            #'yagarto-mac-debug)))
              (should (string-match-p "JSON" message))))
          (cl-letf (((symbol-function 'process-file)
                     (lambda (&rest _arguments)
                       (signal 'file-missing '("Searching for program"
                                               "No such file" "yagarto-mac")))))
            (let ((message (yagarto-mac-test--user-error-message
                            #'yagarto-mac-debug)))
              (should (string-match-p "找不到.*yagarto-mac\\|yagarto-mac.*找不到"
                                      message)))))
      (delete-directory root t))))

(ert-deftest yagarto-mac-debug-surfaces-cli-missing-backend-envelope ()
  (let* ((root (yagarto-mac-test--project))
         (source (expand-file-name "课程 示例.s" root))
         (payload (json-encode
                   '((schemaVersion . 1)
                     (success . :json-false)
                     (exitCode . 5)
                     (error . ((code . "tool.not_found")
                               (message . "未找到工具 qemu-system-arm")))))))
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name source
                default-directory (file-name-as-directory root))
          (cl-letf (((symbol-function 'process-file)
                     (lambda (&rest _arguments) (insert payload) 5))
                    ((symbol-function 'gdb)
                     (lambda (&rest _arguments) (ert-fail "不应启动 GDB"))))
            (let ((message (yagarto-mac-test--user-error-message
                            #'yagarto-mac-debug)))
              (should (string-match-p "tool\\.not_found" message))
              (should (string-match-p "qemu-system-arm" message)))))
      (delete-directory root t))))

(ert-deftest yagarto-mac-disassemble-uses-text-compilation-command ()
  (let* ((root (yagarto-mac-test--project))
         (source (expand-file-name "课程 示例.s" root))
         (yagarto-mac-command "/opt/YAG 工具/yagarto-mac")
         captured)
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name source
                default-directory (file-name-as-directory root))
          (cl-letf (((symbol-function 'compilation-start)
                     (lambda (command &optional mode _name &rest _ignored)
                       (setq captured (list command mode default-directory))
                       (get-buffer-create " *yagarto-disassemble-test*"))))
            (yagarto-mac-disassemble))
          (should (equal (car captured)
                         (mapconcat #'shell-quote-argument
                                    '("/opt/YAG 工具/yagarto-mac"
                                      "disassemble" "--format" "text")
                                    " ")))
          (should (eq (nth 1 captured) 'yagarto-mac-compilation-mode))
          (should (equal (nth 2 captured) (file-name-as-directory root))))
      (kill-buffer " *yagarto-disassemble-test*")
      (delete-directory root t))))

(ert-deftest yagarto-mac-memory-validates-address-and-positive-length ()
  (dolist (address '("0" "0x0" "-1" "1+2" "0xGG" "1; shell" ""))
    (should-error (yagarto-mac--validate-memory-address address)
                  :type 'user-error))
  (should (equal (yagarto-mac--validate-memory-address "0x20000000")
                 "0x20000000"))
  (should (equal (yagarto-mac--validate-memory-address "4096") "4096"))
  (dolist (length '(0 -1 1.5 "8"))
    (should-error (yagarto-mac--validate-memory-length length)
                  :type 'user-error))
  (should (= (yagarto-mac--validate-memory-length 32) 32)))

(ert-deftest yagarto-mac-memory-requires-active-gdb-mi-session ()
  (cl-letf (((symbol-function 'yagarto-mac--active-gdb-session-p)
             (lambda () nil)))
    (let ((message (yagarto-mac-test--user-error-message
                    (lambda () (yagarto-mac-memory "0x20000000" 8)))))
      (should (string-match-p "GDB/MI.*会话\\|会话.*GDB/MI" message)))))

(ert-deftest yagarto-mac-memory-configures-built-in-view-for-exact-byte-count ()
  (let ((memory-buffer (generate-new-buffer " *yagarto-memory-test*"))
        invalidated shown captured)
    (unwind-protect
        (cl-letf (((symbol-function 'yagarto-mac--active-gdb-session-p)
                   (lambda () t))
                  ((symbol-function 'gdb-get-buffer-create)
                   (lambda (type &optional _thread)
                     (should (eq type 'gdb-memory-buffer))
                     memory-buffer))
                  ((symbol-function 'gdb-invalidate-memory)
                   (lambda (&optional signal)
                     (setq invalidated signal
                           captured (list gdb-memory-address-expression
                                          gdb-memory-unit
                                          gdb-memory-rows
                                          gdb-memory-columns
                                          gdb-memory-format))))
                  ((symbol-function 'display-buffer)
                   (lambda (buffer &rest _ignored) (setq shown buffer))))
          (yagarto-mac-memory "0x20000000" 8)
          (should (eq invalidated 'update))
          (should (equal captured '("0x20000000" 1 8 1 "x")))
          (should (eq shown memory-buffer)))
      (kill-buffer memory-buffer))))

(ert-deftest yagarto-mac-process-buffer-can-be-stopped-without-leak ()
  (skip-unless (file-executable-p "/bin/cat"))
  (let* ((buffer (generate-new-buffer " *yagarto-stop-test*"))
         (process (make-process :name "yagarto-stop-test"
                                :buffer buffer
                                :command '("/bin/cat")
                                :connection-type 'pipe
                                :noquery t)))
    (unwind-protect
        (progn
          (yagarto-mac--record-owned-process buffer process)
          (should (process-live-p process))
          (yagarto-mac--stop-buffer-process buffer)
          (accept-process-output process 0.1)
          (should-not (process-live-p process))
          (with-current-buffer buffer
            (should-not yagarto-mac--owned-process)))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest yagarto-mac-stop-gives-cli-a-bounded-cleanup-grace-period ()
  (let ((buffer (generate-new-buffer " *yagarto-grace-test*"))
        (fake-process 'fake-yagarto-process)
        events)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local yagarto-mac--owned-process fake-process))
          (cl-letf (((symbol-function 'get-buffer-process)
                   (lambda (_buffer) fake-process))
                  ((symbol-function 'process-live-p)
                   (lambda (_process) t))
                  ((symbol-function 'interrupt-process)
                   (lambda (_process) (push 'interrupt events)))
                  ((symbol-function 'accept-process-output)
                   (lambda (_process seconds &rest _ignored)
                     (push (list 'grace seconds) events)))
                  ((symbol-function 'delete-process)
                   (lambda (_process) (push 'delete events))))
          (should (yagarto-mac--stop-buffer-process buffer))
          (setq events (nreverse events))
          (should (equal (mapcar (lambda (event)
                                   (if (consp event) (car event) event))
                                 events)
                         '(interrupt grace delete)))
            (should (<= (cadr (nth 1 events)) 1.0))))
      (kill-buffer buffer))))

(ert-deftest yagarto-mac-run-records-process-and-clears-owner-on-natural-exit ()
  (skip-unless (and (file-executable-p "/bin/sh")
                    (file-executable-p "/bin/cat")))
  (let* ((root (yagarto-mac-test--project))
         (source (expand-file-name "课程 示例.s" root))
         (yagarto-mac-command '("/bin/sh" "-c" "exec /bin/cat"))
         run-buffer process)
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name source
                default-directory (file-name-as-directory root))
          (cl-letf (((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _ignored) buffer)))
            (yagarto-mac-run))
          (setq run-buffer yagarto-mac--last-run-buffer
                process (get-buffer-process run-buffer))
          (should (process-live-p process))
          (with-current-buffer run-buffer
            (should (eq yagarto-mac--owned-process process)))
          (process-send-eof process)
          (let ((deadline (+ (float-time) 2.0)))
            (while (and (process-live-p process)
                        (< (float-time) deadline))
              (accept-process-output process 0.05)))
          (accept-process-output nil 0.05)
          (should-not (process-live-p process))
          (with-current-buffer run-buffer
            (should-not yagarto-mac--owned-process)))
      (when (and process (process-live-p process)) (delete-process process))
      (when (buffer-live-p run-buffer) (kill-buffer run-buffer))
      (delete-directory root t))))

(ert-deftest yagarto-mac-stop-never-terminates-process-reusing-stale-run-buffer ()
  (skip-unless (file-executable-p "/bin/cat"))
  (let* ((buffer (generate-new-buffer " *reused-process-test*"))
         (stale-owner (make-process :name "stale-owner-test"
                                    :buffer nil
                                    :command '("/bin/cat")
                                    :connection-type 'pipe
                                    :noquery t))
         (process (make-process :name "reused-process-test"
                                :buffer buffer
                                :command '("/bin/cat")
                                :connection-type 'pipe
                                :noquery t))
         (yagarto-mac--last-run-buffer nil))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local yagarto-mac--owned-process stale-owner)
          (should-error (yagarto-mac-stop) :type 'user-error)
          (should (process-live-p process)))
      (when (process-live-p stale-owner) (delete-process stale-owner))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest yagarto-mac-kill-hook-never-terminates-reused-buffer-process ()
  (skip-unless (file-executable-p "/bin/cat"))
  (let* ((buffer (generate-new-buffer " *reused-kill-hook-test*"))
         (stale-owner (make-process :name "stale-kill-owner-test"
                                    :buffer nil
                                    :command '("/bin/cat")
                                    :connection-type 'pipe
                                    :noquery t))
         (process (make-process :name "reused-kill-hook-test"
                                :buffer buffer
                                :command '("/bin/cat")
                                :connection-type 'pipe
                                :noquery t)))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local yagarto-mac--owned-process stale-owner)
          (yagarto-mac--kill-current-buffer-process)
          (should (process-live-p process)))
      (when (process-live-p stale-owner) (delete-process stale-owner))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest yagarto-mac-stale-sentinel-never-clears-new-owned-process ()
  (skip-unless (file-executable-p "/bin/cat"))
  (let* ((buffer (generate-new-buffer " *sentinel-identity-test*"))
         (old-process (make-process :name "old-sentinel-test"
                                    :buffer buffer
                                    :command '("/bin/cat")
                                    :connection-type 'pipe
                                    :noquery t))
         (new-process (make-process :name "new-sentinel-test"
                                    :buffer buffer
                                    :command '("/bin/cat")
                                    :connection-type 'pipe
                                    :noquery t)))
    (unwind-protect
        (progn
          (process-put old-process 'yagarto-mac-owner-buffer buffer)
          (with-current-buffer buffer
            (setq-local yagarto-mac--owned-process new-process))
          (delete-process old-process)
          (yagarto-mac--run-process-sentinel old-process "finished\n")
          (with-current-buffer buffer
            (should (eq yagarto-mac--owned-process new-process))))
      (when (process-live-p old-process) (delete-process old-process))
      (when (process-live-p new-process) (delete-process new-process))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'yagarto-mac-mode-tests)

;;; yagarto-mac-mode-tests.el ends here
