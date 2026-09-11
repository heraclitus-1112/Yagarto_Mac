;;; yagarto-mac-mode.el --- YAGARTO Mac assembly workflow -*- lexical-binding: t; -*-

;; Copyright (C) 2026 YAGARTO Mac contributors
;; Author: YAGARTO Mac contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.2"))
;; Keywords: tools, languages, hardware
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; `yagarto-mac-mode' connects assembly buffers to the YAGARTO Mac CLI.
;; It delegates target selection and backend policy to the CLI, and uses
;; Emacs' built-in compilation, comint, and GDB/MI facilities for display.

;;; Code:

(require 'cl-lib)
(require 'compile)
(require 'comint)
(require 'gdb-mi)
(require 'json)
(require 'seq)
(require 'subr-x)

(defgroup yagarto-mac nil
  "在 Emacs 中使用 YAGARTO Mac。"
  :group 'tools
  :prefix "yagarto-mac-")

(defcustom yagarto-mac-command "yagarto-mac"
  "YAGARTO Mac 可执行文件或命令列表。

字符串会被当作一个完整的可执行文件名，不会按空格拆分。列表的第一项
是可执行文件，其余项会作为每次调用前置的独立参数。"
  :type '(choice
          (string :tag "可执行文件")
          (repeat :tag "可执行文件和前置参数" string))
  :group 'yagarto-mac)

(defcustom yagarto-mac-profiles
  '("arm7tdmi" "cortex-m4" "stm32f4-discovery")
  "可由 YAGARTO Mac CLI 选择的 profile 列表。"
  :type '(repeat string)
  :group 'yagarto-mac)

(defcustom yagarto-mac-project-file "yagarto.json"
  "用于识别 YAGARTO Mac 项目根目录的配置文件名。"
  :type 'string
  :group 'yagarto-mac)

(defconst yagarto-mac--known-backends
  '("gdb-simulator"
    "qemu-arm926-compatible"
    "qemu-mps2-an386"
    "openocd-stm32f4-discovery"))

(defconst yagarto-mac--json-null (make-symbol "yagarto-mac-json-null")
  "用于区分 JSON null 与空数组的私有哨兵值。")

(defconst yagarto-mac--gnu-error-regexp
  '(yagarto-mac-gnu
    "^\\(.+\\):\\([0-9]+\\):\\(?:\\([0-9]+\\):\\)?[[:space:]]*\\(?:[Ff]atal error\\|[Ee]rror\\|[Ww]arning\\|[Nn]ote\\):"
    1 2 3))

(defvar yagarto-mac--last-run-buffer nil
  "最近一次由 `yagarto-mac-run' 创建的进程缓冲区。")

(defvar yagarto-mac-mode nil
  "非 nil 表示当前缓冲区启用了 YAGARTO Mac 次模式。")

(defvar-local yagarto-mac--project-directory nil)
(defvar-local yagarto-mac--configuration-file nil)
(defvar-local yagarto-mac--configuration-mtime nil)
(defvar-local yagarto-mac--profile nil)
(defvar-local yagarto-mac--profile-error nil)
(defvar-local yagarto-mac--owned-process nil
  "当前缓冲区由 `yagarto-mac-run' 创建并拥有的具体进程对象。")

(defun yagarto-mac--base-command ()
  "返回经过验证的 CLI 基础 argv。"
  (let ((command (if (stringp yagarto-mac-command)
                     (list yagarto-mac-command)
                   yagarto-mac-command)))
    (unless (and (consp command)
                 (cl-every (lambda (item)
                             (and (stringp item) (not (string-empty-p item))))
                           command))
      (user-error "`yagarto-mac-command' 必须是非空可执行路径或非空字符串列表"))
    (copy-sequence command)))

(defun yagarto-mac--command-argv (&rest arguments)
  "把 ARGUMENTS 追加到 CLI 基础 argv。"
  (append (yagarto-mac--base-command) arguments))

(defun yagarto-mac--shell-command (arguments)
  "把独立的 ARGUMENTS 安全转换为 shell 命令字符串。"
  (mapconcat #'shell-quote-argument arguments " "))

(defun yagarto-mac--start-directory ()
  "返回当前缓冲区用于项目查找的目录。"
  (file-name-as-directory
   (expand-file-name
    (if buffer-file-name
        (file-name-directory buffer-file-name)
      default-directory))))

(defun yagarto-mac--project-root (&optional no-error)
  "从当前缓冲区向上查找项目根目录。

若 NO-ERROR 非 nil，找不到时返回 nil；否则触发中文 `user-error'。"
  (let ((root (locate-dominating-file
               (yagarto-mac--start-directory)
               yagarto-mac-project-file)))
    (cond
     (root (file-name-as-directory (expand-file-name root)))
     (no-error nil)
     (t (user-error "未找到 %s；请先在项目目录运行 `yagarto-mac init'"
                    yagarto-mac-project-file)))))

(defun yagarto-mac--required-json-field (object key predicate description)
  "从 OBJECT 取 KEY，并用 PREDICATE 验证为 DESCRIPTION。"
  (let ((cell (assq key object)))
    (unless cell
      (user-error "YAGARTO Mac JSON 缺少字段 `%s'" key))
    (let ((value (cdr cell)))
      (unless (funcall predicate value)
        (user-error "YAGARTO Mac JSON 字段 `%s' 必须是%s" key description))
      value)))

(defun yagarto-mac--nonempty-string-p (value)
  "当 VALUE 是不含控制字符的非空字符串时返回非 nil。"
  (and (stringp value)
       (not (string-empty-p value))
       (not (seq-some (lambda (character)
                        (or (< character 32) (= character 127)))
                      value))))

(defun yagarto-mac--string-list-p (value)
  "当 VALUE 是安全字符串列表时返回非 nil。"
  (and (listp value)
       (cl-every #'yagarto-mac--nonempty-string-p value)))

(defun yagarto-mac--parse-json-buffer (context)
  "严格解析当前缓冲区中的 JSON，并在错误中说明 CONTEXT。"
  (condition-case error-data
      (let ((value (json-parse-buffer
                    :object-type 'alist
                    :array-type 'list
                    :null-object yagarto-mac--json-null
                    :false-object :json-false)))
        (skip-chars-forward " \t\r\n")
        (unless (eobp)
          (user-error "%s JSON 含有尾随内容或第二个对象" context))
        (unless (listp value)
          (user-error "%s JSON 顶层必须是对象" context))
        value)
    (json-error
     (user-error "%s JSON 无法解析：%s" context
                 (error-message-string error-data)))))

(defun yagarto-mac--parse-json-string (text context)
  "把 TEXT 严格解析为 JSON alist，并在错误中说明 CONTEXT。"
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (yagarto-mac--parse-json-buffer context)))

(defun yagarto-mac--configuration-mtime (file)
  "返回 FILE 的修改时间；无法读取时返回 nil。"
  (when-let ((attributes (file-attributes file)))
    (file-attribute-modification-time attributes)))

(defun yagarto-mac--read-configuration (root)
  "读取并验证 ROOT 下的项目配置。"
  (let ((file (expand-file-name yagarto-mac-project-file root)) object)
    (condition-case error-data
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (setq object (yagarto-mac--parse-json-buffer
                        (format "项目配置（%s）" file))))
      (file-error
       (user-error "无法读取项目配置（%s）：%s"
                   file (error-message-string error-data))))
    (let ((schema (yagarto-mac--required-json-field
                   object 'schemaVersion #'integerp "整数"))
          (profile (yagarto-mac--required-json-field
                    object 'profile #'stringp "字符串"))
          (entry (yagarto-mac--required-json-field
                  object 'entry #'stringp "字符串"))
          (output (yagarto-mac--required-json-field
                   object 'outputName #'yagarto-mac--nonempty-string-p
                   "非空字符串")))
      (unless (= schema 1)
        (user-error "不支持项目配置 schemaVersion %s；当前仅支持 1" schema))
      (unless (member profile yagarto-mac-profiles)
        (user-error "项目 profile `%s' 不在可选列表中：%s"
                    profile (string-join yagarto-mac-profiles "、")))
      (list :root root
            :file file
            :mtime (yagarto-mac--configuration-mtime file)
            :schema-version schema
            :profile profile
            :entry entry
            :output-name output))))

;;;###autoload
(defun yagarto-mac-refresh-profile (&optional quiet)
  "重新读取当前项目 profile 并刷新模式行。

QUIET 非 nil 时把错误保存为模式行状态而不触发错误。"
  (interactive)
  (let ((root (yagarto-mac--project-root t)))
    (if (not root)
        (progn
          (setq yagarto-mac--project-directory nil
                yagarto-mac--configuration-file nil
                yagarto-mac--configuration-mtime nil
                yagarto-mac--profile nil
                yagarto-mac--profile-error "无项目")
          (force-mode-line-update t)
          (unless quiet
            (user-error "未找到 %s；请先在项目目录运行 `yagarto-mac init'"
                        yagarto-mac-project-file)))
      (condition-case error-data
          (let ((configuration (yagarto-mac--read-configuration root)))
            (setq yagarto-mac--project-directory root
                  yagarto-mac--configuration-file
                  (plist-get configuration :file)
                  yagarto-mac--configuration-mtime
                  (plist-get configuration :mtime)
                  yagarto-mac--profile (plist-get configuration :profile)
                  yagarto-mac--profile-error nil)
            (force-mode-line-update t)
            (unless quiet
              (message "YAGARTO Mac profile：%s" yagarto-mac--profile))
            configuration)
        (user-error
         (setq yagarto-mac--project-directory root
               yagarto-mac--configuration-file
               (expand-file-name yagarto-mac-project-file root)
               yagarto-mac--configuration-mtime
               (yagarto-mac--configuration-mtime
                (expand-file-name yagarto-mac-project-file root))
               yagarto-mac--profile nil
               yagarto-mac--profile-error "配置错误")
         (force-mode-line-update t)
         (unless quiet
           (signal (car error-data) (cdr error-data)))
         nil)))))

(defun yagarto-mac--refresh-if-stale ()
  "配置根目录或修改时间变化时安静刷新当前缓冲区。"
  (let* ((root (yagarto-mac--project-root t))
         (file (and root (expand-file-name yagarto-mac-project-file root)))
         (mtime (and file (yagarto-mac--configuration-mtime file))))
    (when (or (not (equal root yagarto-mac--project-directory))
              (not (equal file yagarto-mac--configuration-file))
              (not (equal mtime yagarto-mac--configuration-mtime)))
      (yagarto-mac-refresh-profile t))))

(defun yagarto-mac--profile-label (profile)
  "返回 PROFILE 的紧凑模式行标签。"
  (pcase profile
    ("arm7tdmi" "ARM7")
    ("cortex-m4" "M4")
    ("stm32f4-discovery" "STM32")
    ((pred stringp) (upcase profile))
    (_ (or yagarto-mac--profile-error "无项目"))))

(defun yagarto-mac--mode-line ()
  "生成当前缓冲区的 YAGARTO Mac 模式行文本。"
  (when yagarto-mac-mode
    (yagarto-mac--refresh-if-stale)
    (format " YAG[%s]" (yagarto-mac--profile-label yagarto-mac--profile))))

(defun yagarto-mac--call-cli (root arguments)
  "在 ROOT 用独立 argv 同步调用 CLI ARGUMENTS。

返回 `(STATUS . OUTPUT)'。成功时 OUTPUT 只取标准输出，避免命令包装器
写到标准错误的进度信息污染 JSON；失败时优先返回标准错误诊断。"
  (let* ((command (append (yagarto-mac--base-command) arguments))
         (program (car command))
         (argv (cdr command))
         (default-directory root)
         (stderr-file (make-temp-file "yagarto-mac-stderr-")))
    (unwind-protect
        (condition-case error-data
            (with-temp-buffer
              (let* ((status (apply #'process-file program nil
                                    (list t stderr-file) nil argv))
                     (stdout (buffer-string))
                     (stderr (with-temp-buffer
                               (insert-file-contents stderr-file)
                               (buffer-string)))
                     (output (if (and (integerp status) (zerop status))
                                 stdout
                               (if (string-empty-p stderr) stdout stderr))))
                (cons status output)))
          (file-missing
           (user-error "找不到 YAGARTO Mac 命令 `%s'；请安装 CLI 或自定义 `yagarto-mac-command'：%s"
                       program (error-message-string error-data))))
      (ignore-errors (delete-file stderr-file)))))

(defun yagarto-mac--failure-message (output status action)
  "从失败 OUTPUT 中提取 ACTION 和 STATUS 的可操作中文消息。"
  (let ((fallback (string-trim output)))
    (condition-case nil
        (let* ((object (yagarto-mac--parse-json-string output "CLI 错误"))
               (error-object (alist-get 'error object))
               (code (and (listp error-object) (alist-get 'code error-object)))
               (message-text (and (listp error-object)
                                  (alist-get 'message error-object))))
          (if (stringp message-text)
              (format "%s失败（退出状态 %s，%s）：%s"
                      action status (or code "未知错误") message-text)
            (format "%s失败（退出状态 %s）：%s"
                    action status (if (string-empty-p fallback)
                                      "CLI 未提供诊断" fallback))))
      (error
       (format "%s失败（退出状态 %s）：%s"
               action status (if (string-empty-p fallback)
                                 "CLI 未提供诊断" fallback))))))

(defun yagarto-mac--refresh-project-buffers (root)
  "刷新属于 ROOT 的所有活动 YAGARTO Mac 缓冲区。"
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (bound-and-true-p yagarto-mac-mode)
                 (equal (yagarto-mac--project-root t) root))
        (yagarto-mac-refresh-profile t)))))

;;;###autoload
(defun yagarto-mac-select-profile (profile)
  "把当前项目切换到 PROFILE。"
  (interactive
   (list (completing-read "选择 YAGARTO Mac profile："
                          yagarto-mac-profiles nil t nil nil
                          yagarto-mac--profile)))
  (unless (member profile yagarto-mac-profiles)
    (user-error "无效 profile `%s'；可选：%s"
                profile (string-join yagarto-mac-profiles "、")))
  (let* ((root (yagarto-mac--project-root))
         (result (yagarto-mac--call-cli
                  root (list "profile" "set" profile "--format" "text")))
         (status (car result))
         (output (cdr result)))
    (unless (and (integerp status) (zerop status))
      (user-error "%s" (yagarto-mac--failure-message output status "设置 profile")))
    (yagarto-mac--refresh-project-buffers root)
    (message "%s" (if (string-empty-p (string-trim output))
                       (format "已将 profile 设置为 %s" profile)
                     (string-trim output)))))

(define-derived-mode yagarto-mac-compilation-mode compilation-mode
  "YAGARTO-Compile"
  "YAGARTO Mac 构建与反汇编输出模式。"
  (setq-local compilation-error-regexp-alist-alist
              (cons yagarto-mac--gnu-error-regexp
                    (assq-delete-all
                     'yagarto-mac-gnu
                     (copy-tree compilation-error-regexp-alist-alist))))
  (setq-local compilation-error-regexp-alist
              (cons 'yagarto-mac-gnu
                    (delq 'yagarto-mac-gnu
                          (copy-sequence compilation-error-regexp-alist)))))

(defun yagarto-mac--compilation-name (action root)
  "返回 ACTION 在 ROOT 对应的 compilation 缓冲区命名函数。"
  (let ((project (file-name-nondirectory (directory-file-name root))))
    (lambda (_mode-name)
      (format "*yagarto-mac %s: %s*" action project))))

;;;###autoload
(defun yagarto-mac-build ()
  "在项目根目录构建当前 YAGARTO Mac 项目。"
  (interactive)
  (let* ((root (yagarto-mac--project-root))
         (default-directory root)
         (command (yagarto-mac--shell-command
                   (yagarto-mac--command-argv
                    "build" "--format" "text"))))
    (compilation-start
     command
     'yagarto-mac-compilation-mode
     (yagarto-mac--compilation-name "build" root))))

(defun yagarto-mac--run-buffer-name (root)
  "返回 ROOT 的交互运行缓冲区名。"
  (format "*yagarto-mac run: %s*"
          (file-name-nondirectory (directory-file-name root))))

(defun yagarto-mac--run-process-sentinel (process _event)
  "仅在 PROCESS 仍是记录的 owner 时清除其缓冲区所有权。"
  (unless (process-live-p process)
    (let ((buffer (process-get process 'yagarto-mac-owner-buffer)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (eq yagarto-mac--owned-process process)
            (setq yagarto-mac--owned-process nil))))
      (process-put process 'yagarto-mac-owner-buffer nil))))

(defun yagarto-mac--record-owned-process (buffer process)
  "把 BUFFER 的具体 PROCESS 记录为 YAGARTO Mac owner 并安装 sentinel。"
  (when process
    (with-current-buffer buffer
      (setq-local yagarto-mac--owned-process process))
    (process-put process 'yagarto-mac-owner-buffer buffer)
    (unless (process-get process 'yagarto-mac-sentinel-installed)
      (process-put process 'yagarto-mac-sentinel-installed t)
      (let ((previous-sentinel (process-sentinel process)))
        (set-process-sentinel
         process
         (lambda (changed-process event)
           (unwind-protect
               (when previous-sentinel
                 (funcall previous-sentinel changed-process event))
             (yagarto-mac--run-process-sentinel changed-process event))))))
    ;; 极短命令可能在 sentinel 安装前结束；同步应用同一 identity 检查。
    (unless (process-live-p process)
      (yagarto-mac--run-process-sentinel process "finished\n"))
    process))

(defun yagarto-mac--owned-current-process (&optional buffer)
  "返回 BUFFER 中仍与记录 owner identity 相同的活动进程。"
  (let ((buffer (or buffer (current-buffer))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((current-process (get-buffer-process buffer))
              (owned-process yagarto-mac--owned-process))
          (when (and (eq current-process owned-process)
                     owned-process
                     (process-live-p owned-process))
            owned-process))))))

(defun yagarto-mac--stop-buffer-process (&optional buffer)
  "有界停止 BUFFER 中的进程，并返回是否找到活动进程。"
  (let* ((buffer (or buffer (current-buffer)))
         (process (yagarto-mac--owned-current-process buffer)))
    (when process
      (condition-case nil
          (progn
            (interrupt-process process)
            ;; CLI 自己会有界转发信号并回收 GDB/QEMU/OpenOCD 进程组。
            ;; 给它短暂机会完成清理，再强制删除仍存活的直接进程。
            (accept-process-output process 0.75))
        (error nil))
      (when (process-live-p process)
        (delete-process process))
      t)))

(defun yagarto-mac--kill-current-buffer-process ()
  "在运行缓冲区被关闭时清理其子进程。"
  (yagarto-mac--stop-buffer-process (current-buffer)))

;;;###autoload
(defun yagarto-mac-stop ()
  "停止当前或最近一次 YAGARTO Mac `run' 进程。"
  (interactive)
  (let ((buffer (if (yagarto-mac--owned-current-process (current-buffer))
                    (current-buffer)
                  yagarto-mac--last-run-buffer)))
    (unless (and (buffer-live-p buffer)
                 (yagarto-mac--stop-buffer-process buffer))
      (user-error "当前没有可停止的 YAGARTO Mac 运行进程"))
    (message "已停止 YAGARTO Mac 运行进程")))

;;;###autoload
(defun yagarto-mac-run ()
  "用 comint 和 text 格式启动当前项目的交互运行会话。"
  (interactive)
  (let* ((root (yagarto-mac--project-root))
         (command (yagarto-mac--command-argv "run" "--format" "text"))
         (program (car command))
         (arguments (cdr command))
         (name (yagarto-mac--run-buffer-name root))
         (buffer (get-buffer-create name)))
    (when (comint-check-proc buffer)
      (user-error "项目已有运行中的会话；请先执行 `yagarto-mac-stop'"))
    (with-current-buffer buffer
      (setq default-directory root))
    (condition-case error-data
        (let ((default-directory root))
          (apply #'make-comint-in-buffer name buffer program nil arguments))
      (file-missing
       (kill-buffer buffer)
       (user-error "找不到 YAGARTO Mac 命令 `%s'；请安装 CLI 或自定义 `yagarto-mac-command'：%s"
                   program (error-message-string error-data))))
    (with-current-buffer buffer
      (add-hook 'kill-buffer-hook
                #'yagarto-mac--kill-current-buffer-process nil t))
    (yagarto-mac--record-owned-process buffer (get-buffer-process buffer))
    (setq yagarto-mac--last-run-buffer buffer)
    (pop-to-buffer buffer)))

(defun yagarto-mac--parse-debug-plan (text)
  "严格解析 CLI 输出的调试计划 TEXT，并返回规范化 plist。"
  (let* ((object (yagarto-mac--parse-json-string text "调试计划"))
         (profile (yagarto-mac--required-json-field
                   object 'profile #'stringp "字符串"))
         (backend (yagarto-mac--required-json-field
                   object 'backend #'stringp "字符串"))
         (gdb-executable (yagarto-mac--required-json-field
                          object 'gdbExecutable
                          #'yagarto-mac--nonempty-string-p "安全的非空字符串"))
         (gdb-arguments (yagarto-mac--required-json-field
                         object 'gdbArguments
                         #'yagarto-mac--string-list-p "字符串数组"))
         (init-commands (yagarto-mac--required-json-field
                         object 'initCommands
                         #'yagarto-mac--string-list-p "字符串数组"))
         (warnings (yagarto-mac--required-json-field
                    object 'warnings
                    #'yagarto-mac--string-list-p "字符串数组"))
         (elf (yagarto-mac--required-json-field
               object 'elf #'yagarto-mac--nonempty-string-p "安全的非空字符串"))
         (project-directory
          (yagarto-mac--required-json-field
           object 'projectDirectory
           #'yagarto-mac--nonempty-string-p "安全的非空字符串")))
    (unless (member profile yagarto-mac-profiles)
      (user-error "调试计划 profile `%s' 无效" profile))
    (unless (member backend yagarto-mac--known-backends)
      (user-error "调试计划 backend `%s' 无效" backend))
    (list :profile profile
          :backend backend
          :gdb-executable gdb-executable
          :gdb-arguments gdb-arguments
          :init-commands init-commands
          :warnings warnings
          :elf elf
          :project-directory project-directory)))

(defun yagarto-mac--normalize-gdb-arguments (arguments)
  "把 ARGUMENTS 中的 `-ex CMD' 规范化为单个 `-ex=CMD' argv。"
  (let (normalized)
    (while arguments
      (let ((argument (pop arguments)))
        (if (equal argument "-ex")
            (progn
              (unless arguments
                (user-error "调试计划 gdbArguments 含有孤立的 `-ex'"))
              (push (concat "-ex=" (pop arguments)) normalized))
          (push argument normalized))))
    (nreverse normalized)))

(defun yagarto-mac--gdb-command (plan)
  "把规范化 PLAN 转换为 Emacs GDB/MI 可逆命令字符串。"
  (let* ((arguments (yagarto-mac--normalize-gdb-arguments
                     (copy-sequence (plist-get plan :gdb-arguments))))
         (mi-arguments (if (member "-i=mi" arguments)
                           arguments
                         (cons "-i=mi" arguments))))
    ;; `gud-common-init' 用 `split-string-and-unquote' 逆向解析此字符串；
    ;; combine-and-quote-strings 是对应的编码器。不要在这里执行 initCommands：
    ;; CLI 已把每条初始化指令放入 gdbArguments 的 -ex 参数。
    (combine-and-quote-strings
     (cons (plist-get plan :gdb-executable) mi-arguments))))

;;;###autoload
(defun yagarto-mac-debug ()
  "从 CLI dry-run 计划启动 Emacs 内置 GDB/MI many-windows 调试。"
  (interactive)
  (let* ((root (yagarto-mac--project-root))
         (result (yagarto-mac--call-cli
                  root '("debug" "--dry-run" "--format" "json")))
         (status (car result))
         (output (cdr result)))
    (unless (and (integerp status) (zerop status))
      (user-error "%s" (yagarto-mac--failure-message output status "生成调试计划")))
    (let ((plan (yagarto-mac--parse-debug-plan output)))
      (dolist (warning (plist-get plan :warnings))
        (display-warning 'yagarto-mac
                         (format "YAGARTO Mac 调试警告：%s" warning)
                         :warning))
      (setq gdb-many-windows t)
      (let ((default-directory root))
        (gdb (yagarto-mac--gdb-command plan))))))

;;;###autoload
(defun yagarto-mac-disassemble (&optional elf)
  "反汇编当前项目；ELF 非 nil 时改为反汇编指定文件。"
  (interactive
   (list (when current-prefix-arg
           (read-file-name "选择要反汇编的 ELF：" nil nil t))))
  (let* ((root (yagarto-mac--project-root))
         (arguments (append '("disassemble")
                            (when elf (list (expand-file-name elf)))
                            '("--format" "text")))
         (default-directory root)
         (command (yagarto-mac--shell-command
                   (apply #'yagarto-mac--command-argv arguments))))
    (compilation-start
     command
     'yagarto-mac-compilation-mode
     (yagarto-mac--compilation-name "disassemble" root))))

(defun yagarto-mac--validate-memory-address (address)
  "验证 ADDRESS 是正十六进制或十进制整数，并返回它。"
  (unless (and (stringp address)
               (string-match-p
                "\\`\\(?:0[xX][[:xdigit:]]+\\|[1-9][0-9]*\\)\\'"
                address)
               (> (if (string-match-p "\\`0[xX]" address)
                      (string-to-number (substring address 2) 16)
                    (string-to-number address 10))
                  0))
    (user-error "内存地址必须是正十六进制（如 0x20000000）或十进制整数"))
  address)

(defun yagarto-mac--validate-memory-length (length)
  "验证 LENGTH 是正整数字节数，并返回它。"
  (unless (and (integerp length) (> length 0))
    (user-error "内存长度必须是正整数（字节）"))
  length)

(defun yagarto-mac--active-gdb-session-p ()
  "当前是否存在活动的 Emacs GDB/MI 会话。"
  (and (boundp 'gud-comint-buffer)
       (buffer-live-p gud-comint-buffer)
       (let ((process (get-buffer-process gud-comint-buffer)))
         (and process (process-live-p process)))
       (eq (buffer-local-value 'gud-minor-mode gud-comint-buffer) 'gdbmi)))

;;;###autoload
(defun yagarto-mac-memory (address length)
  "在活动 GDB/MI 会话中从 ADDRESS 显示 LENGTH 字节内存。"
  (interactive
   (list (read-string "内存起始地址（十六进制或十进制正整数）：" "0x20000000")
         (read-number "读取长度（字节，正整数）：" 32)))
  (setq address (yagarto-mac--validate-memory-address address)
        length (yagarto-mac--validate-memory-length length))
  (unless (yagarto-mac--active-gdb-session-p)
    (user-error "没有活动的 Emacs GDB/MI 会话；请先执行 `yagarto-mac-debug'"))
  (let ((gdb-memory-address-expression address)
        (gdb-memory-unit 1)
        (gdb-memory-rows length)
        (gdb-memory-columns 1)
        (gdb-memory-format "x"))
    (let ((buffer (gdb-get-buffer-create 'gdb-memory-buffer)))
      (with-current-buffer buffer
        (setq-local gdb-memory-address-expression address
                    gdb-memory-unit 1
                    gdb-memory-rows length
                    gdb-memory-columns 1
                    gdb-memory-format "x")
        (gdb-invalidate-memory 'update))
      (display-buffer buffer))))

(defvar-keymap yagarto-mac-mode-map
  :doc "`yagarto-mac-mode' 的固定快捷键。"
  "C-c C-p" #'yagarto-mac-select-profile
  "C-c C-b" #'yagarto-mac-build
  "C-c C-r" #'yagarto-mac-run
  "C-c C-d" #'yagarto-mac-debug
  "C-c C-i" #'yagarto-mac-disassemble
  "C-c C-m" #'yagarto-mac-memory)

;;;###autoload
(define-minor-mode yagarto-mac-mode
  "面向 `.s'/`.S' 汇编缓冲区的 YAGARTO Mac 次模式。"
  :lighter (:eval (yagarto-mac--mode-line))
  :keymap yagarto-mac-mode-map
  (if yagarto-mac-mode
      (yagarto-mac-refresh-profile t)
    (setq yagarto-mac--project-directory nil
          yagarto-mac--configuration-file nil
          yagarto-mac--configuration-mtime nil
          yagarto-mac--profile nil
          yagarto-mac--profile-error nil)
    (force-mode-line-update t)))

(provide 'yagarto-mac-mode)

;;; yagarto-mac-mode.el ends here
