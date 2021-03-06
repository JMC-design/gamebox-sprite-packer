(in-package :box.sprite-packer)

(defclass rect ()
  ((%file :reader file
          :initarg :file)
   (%id :reader id
        :initarg :id)
   (%x :reader x
       :initarg :x)
   (%y :reader y
       :initarg :y)
   (%w :reader w
       :initarg :w)
   (%h :reader h
       :initarg :h)))

(defun rect (file id x y w h)
  (make-instance 'rect :file file :id id :x x :y y :w w :h h))

(defun delta-weight (width height rect)
  (min (- (w rect) width) (- (h rect) height)))

(defun find-free-rect (width height rects)
  (unless rects (error "Cannot pack anymore rectangles."))
  (loop :with min-rect = (first rects)
        :with min-delta = (delta-weight width height min-rect)
        :for rect :in (rest rects)
        :for current-delta = (delta-weight width height rect)
        :when (or (minusp min-delta)
                  (and (not (minusp current-delta))
                       (< current-delta min-delta)))
          :do (setf min-rect rect
                    min-delta current-delta)
        :finally (return (if (minusp min-delta)
                             (error "Cannot pack anymore rectangles.")
                             min-rect))))

(defun intersectsp (rect1 rect2)
  (with-slots ((x1 %x) (y1 %y) (w1 %w) (h1 %h)) rect1
    (with-slots ((x2 %x) (y2 %y) (w2 %w) (h2 %h)) rect2
      (and (< x1 (+ x2 w2))
           (> (+ x1 w1) x2)
           (< y1 (+ y2 h2))
           (> (+ y1 h1) y2)))))

(defun subdivide-rect (rect placed)
  (flet ((splitsp (coord from to)
           (> to coord from)))
    (if (intersectsp placed rect)
        (with-slots (%file %id %x %y %w %h) rect
          (with-slots ((px %x) (py %y) (pw %w) (ph %h)) placed
            (let ((result))
              (when (splitsp px %x (+ %x %w))
                (push (rect %file %id %x %y (- px %x) %h) result))
              (when (splitsp (+ px pw) %x (+ %x %w))
                (push (rect %file %id (+ px pw) %y (- (+ %x %w) (+ px pw)) %h) result))
              (when (splitsp py %y (+ %y %h))
                (push (rect %file %id %x %y %w (- py %y)) result))
              (when (splitsp (+ py ph) %y (+ %y %h))
                (push (rect %file %id %x (+ py ph) %w (- (+ %y %h) (+ py ph))) result))
              result)))
        (list rect))))

(defun containsp (outer inner)
  (with-slots ((ox %x) (oy %y) (ow %w) (oh %h)) outer
    (with-slots ((ix %x) (iy %y) (iw %w) (ih %h)) inner
      (and (>= (+ ox ow) (+ ix iw) ix ox)
           (>= (+ oy oh) (+ iy ih) iy oy)))))

(defun normalize-free-space (rects)
  (remove
   nil
   (loop :with rest-filtered = rects
         :for (rect . rest) = rest-filtered
         :while rect
         :collect (loop :with containedp
                        :for other-rect :in rest
                        :unless (containsp rect other-rect)
                          :collect other-rect :into filtered
                        :when (and (not containedp)
                                   (containsp other-rect rect))
                          :do (setf containedp t)
                        :finally (setf rest-filtered filtered)
                                 (return (unless containedp rect))))))

(defun resolve-free-rects (rect free-rects)
  (normalize-free-space
   (loop :for free-rect :in free-rects
         :append (subdivide-rect free-rect rect))))

(defun place-rect (rect free-rects)
  (with-slots (%file %id %w %h) rect
    (with-slots ((fx %x) (fy %y)) (find-free-rect %w %h free-rects)
      (let ((placed (rect %file %id fx fy %w %h)))
        (list placed (resolve-free-rects placed free-rects))))))

(defun sort-rects (rects)
  (labels ((apply-fn (fn rect)
             (funcall fn (w rect) (h rect)))
           (sort-by (rects fn)
             (stable-sort rects #'> :key (lambda (x) (apply-fn fn x)))))
    (sort-by (sort-by rects #'min) #'max)))

(defun pack-rects (rects width height)
  (loop :with free-rects = (list (rect nil nil 0 0 width height))
        :for rect :in (sort-rects rects)
        :for (placed new-free-rects) = (place-rect rect free-rects)
        :do (setf free-rects new-free-rects)
        :collect placed))

(defun make-id (root file)
  (namestring
   (make-pathname
    :defaults
    (uiop/pathname:enough-pathname file (uiop/pathname:ensure-directory-pathname root))
    :type nil)))

(defun map-files (path effect &key (filter (constantly t)) (recursive t))
  (labels ((maybe-affect (file)
             (when (funcall filter file)
               (funcall effect file)))
           (process-files (dir)
             (map nil #'maybe-affect (uiop/filesystem:directory-files dir))))
    (uiop/filesystem:collect-sub*directories
     (uiop/pathname:ensure-directory-pathname path)
     t recursive #'process-files)))

(defun collect-files (path &key recursive)
  (let ((files))
    (map-files
     path
     (lambda (x) (push (cons x (make-id path x)) files))
     :recursive recursive)
    (reverse files)))

(defun make-rects (files)
  (loop :for (file . id) :in files
        :for image = (pngload:load-file file :decode nil)
        :for width = (pngload:width image)
        :for height = (pngload:height image)
        :collect (rect file id 0 0 width height)))

(defun add-padding (rects padding)
  (when (and padding (plusp padding))
    (dolist (rect rects)
      (incf (slot-value rect '%w) padding)
      (incf (slot-value rect '%h) padding)))
  rects)

(defun remove-padding (rects padding)
  (when (and padding (plusp padding))
    (loop :with padding/2 = (floor padding 2)
          :for rect :in rects
          :do (incf (slot-value rect '%x) padding/2)
              (incf (slot-value rect '%y) padding/2)
              (decf (slot-value rect '%w) padding)
              (decf (slot-value rect '%h) padding)))
  rects)

(defgeneric make-coords (rect width height normalize flip-y)
  (:method (rect width height normalize flip-y)
    (with-slots (%y %h) rect
      (let ((y (if flip-y (- height %y %h) %y)))
        (list :x (x rect) :y y :w (w rect) :h (h rect)))))
  (:method (rect width height (normalize (eql t)) flip-y)
    (with-slots (%y %h) rect
      (let ((y (if flip-y (- height %y %h) %y)))
        (list :x (float (/ (x rect) width))
              :y (float (/ y height))
              :w (float (/ (w rect) width))
              :h (float (/ (h rect) height)))))))

(defun write-atlas (atlas sprite rect)
  (let ((sprite (opticl:coerce-image sprite 'opticl:rgba-image)))
    (opticl:do-pixels (i j) sprite
      (setf (opticl:pixel atlas (+ i (y rect)) (+ j (x rect)))
            (opticl:pixel sprite i j)))))

(defun write-metadata (data out-file)
  (let ((out-file (make-pathname :defaults out-file :type "spec"))
        (data (sort data #'string< :key (lambda (x) (getf x :id)))))
    (with-open-file (out out-file
                         :direction :output
                         :if-exists :supersede
                         :if-does-not-exist :create)
      (write data :stream out))))

(defun make-atlas (file-spec &key out-file width height normalize flip-y (padding 0))
  "Pack the sprites defined by FILE-SPEC into a spritesheet.

OUT-FILE: A pathname specifying where to write the image file.

WIDTH: The width in pixels of the spritesheet.

HEIGHT: The height in pixels of the spritesheet.

NORMALIZE: Boolean specifying whether to map the metadata's coordinates to the [0..1] range.

FLIP-Y: Boolean specifying whether to flip the Y axis when writing the metadata.

PADDING: The padding in pixels to use around each sprite in the spritesheet.

See MAKE-ATLAS-FROM-DIRECTORY if you want to automatically generate FILE-SPEC from the files under a
given filesystem path.
"
  (loop :with atlas = (opticl:make-8-bit-rgba-image width height)
        :with rects = (add-padding (make-rects file-spec) padding)
        :for rect :in (remove-padding (pack-rects rects width height) padding)
        :for sprite = (opticl:read-png-file (file rect))
        :for coords = (make-coords rect width height normalize flip-y)
        :do (write-atlas atlas sprite rect)
        :collect `(:id ,(id rect) ,@coords) :into data
        :finally (return
                   (values (write-metadata data out-file)
                           (opticl:write-image-file out-file atlas)))))

(defun make-atlas-from-directory (path &key recursive out-file width height normalize flip-y
                                         (padding 0))
  "Pack the sprites located under the given filesystem path, PATH.

RECURSIVE: Boolean specifying whether to scan recursively for files.

OUT-FILE: A pathname specifying where to write the image file.

WIDTH: The width in pixels of the spritesheet.

HEIGHT: The height in pixels of the spritesheet.

NORMALIZE: Boolean specifying whether to normalize the metadata's coordinates in the [0..1] range.

FLIP-Y: Boolean specifying whether to flip the Y axis when writing the metadata.

PADDING: The padding in pixels to use around each sprite in the spritesheet.

See MAKE-ATLAS if you want to manually specify a file-spec, in case you want to be in control of the
names chosen to identify the sprites written to the metadata file.
"
  (let ((file-spec (collect-files path :recursive recursive)))
    (make-atlas file-spec
                :out-file out-file
                :width width
                :height height
                :normalize normalize
                :flip-y flip-y
                :padding padding)))
