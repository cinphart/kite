;;; kite-object.el --- Kite object inspector implementation

;; Copyright (C) 2012 Julian Scheid

;; Author: Julian Scheid <julians37@gmail.com>
;; Keywords: tools
;; Package: kite
;; Compatibility: GNU Emacs 24

;; This file is not part of GNU Emacs.

;; Kite is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; Kite is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
;; License for more details.

;; You should have received a copy of the GNU General Public License
;; along with Kite.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This package implements a JavaScript object inspector.
;;
;; It is part of Kite, a WebKit inspector front-end.


;;; Code:

(defvar kite-object-mode-map
  (let ((map (copy-keymap
              (make-composed-keymap
               widget-keymap
               special-mode-map))))
    (define-key map "g" 'kite-object-refresh)
    (define-key map (kbd "RET") 'kite--object-toggle-disclosure)
    map)
  "Local keymap for `kite-object-mode' buffers.")

(define-derived-mode kite-object-mode special-mode "kite-object"
  "Toggle kite console mode."
  (set (make-local-variable 'widget-link-prefix) "")
  (set (make-local-variable 'widget-link-suffix) "")
  (setq buffer-read-only nil)

  (setq widget-global-map
        (let ((map (copy-keymap widget-global-map)))
          (define-key map (kbd "RET") 'kite--object-toggle-disclosure)
          map)))

(defun kite--object-toggle-widget (widget &rest ignore)
  (when (widget-member widget :kite-disclosed)
    (widget-children-value-delete widget)
    (let ((overlays (mapcar (lambda (overlay)
                              (list overlay
                                    (overlay-start overlay)
                                    (overlay-end overlay)))
                            (overlays-at
                             (- (widget-get widget :from) 1)))))
      (widget-put widget :kite-disclosed
                  (not (widget-get widget :kite-disclosed)))
      (widget-value-set widget (widget-value widget))
      ;; Re-inserting the value causes end of previous
      ;; overlays (if any) to move, so fix'em up.
      (dolist (overlay overlays)
        (apply 'move-overlay overlay)))
    (if (widget-get widget :kite-disclosed)
        (lexical-let ((parent-widget widget))
          (kite-send
           "Runtime.getProperties"
           (list (cons 'objectId
                       (widget-get widget :kite-object-id))
                 (cons 'ownProperties t))
           (lambda (response)
             (kite--object-insert-child-props-async
              parent-widget
              response)))))))

(defun kite--object-insert-child-props-async (parent-widget response)
  (let ((inhibit-read-only t))
    (save-excursion
      (widget-end-of-line)
      (let ((overlays (mapcar (lambda (overlay)
                                (list overlay
                                      (overlay-start overlay)
                                      (overlay-end overlay)))
                              (overlays-at (- (point) 1)))))
      (widget-put
       parent-widget
       :children
       (mapcar
        (lambda (property)
          (kite--object-create-property-widget parent-widget property))
        (sort (append (plist-get (plist-get response :result) :result) nil)
              (lambda (a b)
                (or (string= (plist-get b :name) "__proto__")
                    (and (not (string= (plist-get a :name) "__proto__"))
                         (string< (plist-get a :name)
                                  (plist-get b :name))))))))
      (dolist (overlay overlays)
        (apply 'move-overlay overlay)))))
  (widget-setup))

(defun kite--object-format-value (property)
  (let ((value-type (plist-get (plist-get property :value) :type))
        (value-subtype (plist-get (plist-get property :value) :subtype)))
    (cond
     ((or (and (string= value-type "object")
               (not (string= value-subtype "null")))
          (string= value-type "function"))
      (propertize
       (plist-get (plist-get property :value) :description)
       'face 'kite-object))
     ((string= value-type "number")
      (propertize
       (plist-get (plist-get property :value) :description)
       'face 'kite-number))
     ((string= value-type "boolean")
      (propertize
       (if (plist-get (plist-get property :value) :value)
           "true" "false")
       'face 'kite-boolean))
     ((string= value-type "string")
      (concat
       (propertize "\"" 'face 'kite-quote)
       (propertize
        (plist-get (plist-get property :value) :value)
        'face 'kite-string)
       (propertize "\"" 'face 'kite-quote)))
     ((and (string= value-type "object")
           (string= value-subtype "null"))
      (propertize "null" 'face 'kite-null))
     (t
      (propertize "(unknown)" 'face 'error)))))

(defun kite--object-create-property-widget (parent-widget property)
  (let ((value-type (plist-get (plist-get property :value) :type))
        (value-subtype (plist-get (plist-get property :value) :subtype))
        (value (kite--object-format-value property))
        (name (propertize (plist-get property :name) 'face
                          (if (eq (plist-get property :enumerable) t)
                              'kite-property-name
                            'kite-proto-property-name))))

    (kite--log "kite--object-create-property-widget, property=%s" property)

     (if (or (and (string= value-type "object")
                  (not (string= value-subtype "null")))
             (string= value-type "function"))
         (widget-create-child-and-convert
          parent-widget
          'item ;;'editable-field
          :format "%n%+%t: %[%v%]"
          :value-create (lambda (widget) (insert (widget-get widget :value)))
          :size 1
          :offset 2
          :format-handler 'kite-property-widget-format-handler
          :kite-disclosed nil
          :tag name
          :kite-parent-object-id (widget-get parent-widget :kite-object-id)
          :kite-object-id (plist-get (plist-get property :value) :objectId)
          value)
       (widget-create-child-and-convert
        parent-widget
        'item ;;'editable-field
        :size 1
        :value-create (lambda (widget) (insert (widget-get widget :value)))
        :action 'ignore
        :tag name
        :format "%n %t: %[%v%]"
        :kite-parent-object-id (widget-get parent-widget :kite-object-id)
        :notify (lambda (widget &rest ignore)
                  (put-text-property (widget-field-start widget)
                                     (widget-field-end widget)
                                     'face
                                     'kite-number))
        value))))

(defun kite-property-widget-format-handler (widget escape)
  (cond ((eq escape ?+)
         (if (widget-get widget :kite-disclosed)
             (widget-insert "-")
           (widget-insert "+")))
        (t
         (widget-default-format-handler widget escape))))

(defun kite-inspect-object (object-id object-description)
  (lexical-let ((kite-session kite-session)
                (buffer (get-buffer-create "*kite object inspector*")))
    (with-current-buffer buffer
      (kite-object-mode)
      (let ((inhibit-read-only t))
        (erase-buffer))
      (remove-overlays)
      (set (make-local-variable 'kite-session) kite-session)
      (set (make-local-variable 'widget-link-prefix) "")
      (set (make-local-variable 'widget-link-suffix) "")

      (save-excursion
        (set (make-local-variable 'kite-object-widget)
             (widget-create 'item
                            :size 1
                            :offset 2
                            :kite-disclosed nil
                            :kite-root-object t
                            :format "%v"
                            :kite-object-id object-id
                            object-description))
        (widget-setup)
        (kite--object-toggle-widget kite-object-widget)))
    (switch-to-buffer buffer)))

(defun kite--object-toggle-disclosure ()
  (interactive)
  (beginning-of-line)
  (widget-move 1)
  (let ((widget (widget-at)))
    (when (and widget
               (not (widget-member widget :kite-root-object)))
      (kite--object-toggle-widget widget))))

(defun kite--object-find-all-object-ids (widget &optional all-object-ids)
  (let ((object-id (widget-get widget :kite-parent-object-id)))
    (when object-id
      (setq all-object-ids (cons object-id all-object-ids))))
  (dolist (child (widget-get widget :children))
    (setq all-object-ids
          (kite--object-find-all-object-ids child
                                            all-object-ids)))
  all-object-ids)

(defun kite--object-update-widget (widget all-responses)
  (let* ((object-properties (gethash (widget-get
                                      widget
                                      :kite-parent-object-id)
                                     all-responses))
         (property (and object-properties
                        (gethash
                         (substring-no-properties
                          (widget-get widget :tag))
                         object-properties))))
    (when property
      (save-excursion
        (let* ((button-overlay (widget-get widget :button-overlay))
               (from (and button-overlay (overlay-start button-overlay)))
               (to (and button-overlay (overlay-end button-overlay)))
               (value (kite--object-format-value property)))
          (kite--log "replacing value at %s to %s with %s" from to value)
          (if (and from to)
              (let ((inhibit-read-only t))
                (goto-char from)
                (insert value)
                (move-overlay button-overlay
                              from (overlay-end button-overlay))
                (delete-char (- to from)))
            (widget-field-value-set widget value))))))
  (dolist (child (widget-get widget :children))
    (kite--object-update-widget child all-responses)))

(defun kite-object-refresh ()
  (interactive)
  (if (not (boundp 'kite-object-widget))
      (error "This doesn't seem to be a kite object inspection buffer")
    (lexical-let* ((all-object-ids
                    (delete-dups (kite--object-find-all-object-ids
                                  kite-object-widget)))
                   (all-responses (make-hash-table
                                   :test 'equal
                                   :size (length all-object-ids))))
      (dolist (object-id all-object-ids)
        (lexical-let ((object-id object-id))
          (kite-send
           "Runtime.getProperties"
           (list (cons 'objectId object-id)
                 (cons 'ownProperties t))
           (lambda (response)
             (let* ((properties
                     (plist-get (plist-get response :result) :result))
                    (property-map
                     (make-hash-table :test 'equal
                                      :size (length properties))))
               (mapcar (lambda (property)
                         (puthash (plist-get property :name)
                                  property
                                  property-map))
                       properties)
               (puthash object-id property-map all-responses))
             (when (eq (hash-table-count all-responses)
                       (length all-object-ids))
               (kite--object-update-widget
                kite-object-widget
                all-responses)))))))))

(defun kite-property-widget-value-set (widget value)
  (save-excursion
    (let* ((begin (progn
                    (save-excursion
                      (goto-char (1+ (widget-get widget :from)))
                      (search-forward ":")
                      (forward-char 1)
                      (point))))
           (end (progn 
                  (save-excursion
                    (goto-char begin)
                    (end-of-line)
                    (point)))))
      (message "kite-property-widget-value-set, begin=%s end=%s" begin end)
      (goto-char end)
      (widget-specify-insert
       (insert value))
      (let ((inhibit-read-only t))
        (delete-region begin end)))))


(provide 'kite-object)

;;; kite-object.el ends here
