(in-package #:sdf)

(defparameter *default-characters*
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.,;:?!@#$%^&*()-_<>'\"[]/\\| ")

(defun dist (image x y w h search sdf-scale)
  (declare (optimize speed (debug 0)))
  (check-type search (unsigned-byte 16))
  (check-type y (unsigned-byte 16))
  (check-type x (unsigned-byte 16))
  (check-type w (unsigned-byte 16))
  (check-type h (unsigned-byte 16))
  (check-type sdf-scale (unsigned-byte 16))
  (check-type image (simple-array (unsigned-byte 8) (* * 3)))

  (locally (declare (type (simple-array (unsigned-byte 8) (* * 3)) image))
    (let* ((d (float search 1.0))
           (xs (float (* x sdf-scale) 1.0))
           (ys (float (* y sdf-scale) 1.0))
           (fsearch (float search 1.0))
           (px (aref image (floor (* y sdf-scale)) (floor (* x sdf-scale)) 0)))
      (declare (type (single-float 0.0 65536.0) d))
      (check-type xs (single-float 0.0 65536.0))
      (check-type ys (single-float 0.0 65536.0))
      (locally (declare (type (single-float 0.0 65536.0) xs ys fsearch)
                        (type (unsigned-byte 16) w h))
        (flet ((x (y2 dy)
                 (declare (fixnum dy))
                 (loop for x2 from (max 0
                                        (floor
                                         (- xs (min (1+ d )
                                                    fsearch))))
                         below (min w
                                    (ceiling
                                     (+ xs (min (1+ d)
                                                fsearch))))
                       for px2 = (aref image y2 x2 0)
                       do (when (/= px px2)
                            (setf d
                                  (min d
                                       (sqrt
                                        (+ (expt (- x2 xs) 2)
                                           (expt (float dy 1.0) 2)))))))))
          (x (floor ys) 0)
          (loop for dy fixnum from 1 below search
                do (when (< dy search)
                     (let ((a (floor (- ys dy)))
                           (b (floor (+ ys dy))))
                       (declare (fixnum a b))
                       (when (> a 0)
                         (x a dy))
                       (when (< b h)
                         (x b dy))))
                   ;; early out of outer search loop
                   ;; when distance to scanline is
                   ;; more than best distance
                when (> dy d)
                  return nil)))
      (if (plusp px) d (- d)))))

(defun sdf (font glyph font-scale sdf-scale spread)
  (let* ((scale (* sdf-scale font-scale))
         (gw (- (xmax glyph) (xmin glyph)))
         (gh (- (ymax glyph) (ymin glyph)))
         (padding (ceiling (* 1/2 spread font-scale (units/em font))))
         (search (ceiling (* 1/2 spread scale (units/em font))))
         (dw (+ (* 2 padding) (ceiling (* font-scale gw))))
         (dh (+ (* 2 padding) (ceiling (* font-scale gh))))
         (w (* dw sdf-scale))
         (h (* dh sdf-scale)))
    (declare (fixnum w h))
    (let* ((image (aa-misc:make-image w h #(0 0 0)))
           (state (aa:make-state))
           (px (aa-misc:image-put-pixel image #(255 255 255))))
      (vectors:update-state
       state (paths-ttf:paths-from-glyph
              glyph
              :offset (paths:make-point (- (/ (- w (* scale gw)) 2)
                                           (* (xmin glyph) scale))
                                        (- (/ (- h (* scale gh)) 2)
                                           (* (ymin glyph) scale)))
              :scale-x scale
              :scale-y scale))
      (aa:cells-sweep state (lambda (x y a)
                              (if (>= (abs a) 128)
                                  (funcall px x y 255))))
      (time
       (let* ((dest (aa-misc:make-image dw dh #(0 0 0)))
              (write (aa-misc:image-put-pixel dest #(255 255 255)))
              )
         (declare ;(type (simple-array (unsigned-byte 8) 3) dest image)
          (type (unsigned-byte 16) search))
         (loop for y below (array-dimension dest 0)
               do (loop for x below (array-dimension dest 1)
                        for d = (dist image x y w h search sdf-scale)
                        do (funcall write x y (+ 128 (* 128 (/ d search))))))
         #++(aa-misc:save-image "/tmp/font2.pnm" dest :pnm)
         #++(aa-misc:save-image "/tmp/font2h.pnm" image :pnm)
         (values dest padding))))))

(defmacro with-glyph-data ((glyph metrics &optional (sdf (gensym)) (padding (gensym))) data &body body)
  `(destructuring-bind (&key ((:glyph ,glyph))
                             ((:metrics ,metrics))
                             ((:sdf ,sdf))
                             ((:padding ,padding)) &allow-other-keys)
       ,data
     (declare (ignorable ,glyph ,metrics ,sdf ,padding))
     ,@body))


(defun make-kerning-table (glyph-data scale font)
  (loop with table = (make-hash-table :test 'equal)
     for d0 in glyph-data
     do (loop for d1 in glyph-data
           do (with-glyph-data (g0 m0) d0
                (with-glyph-data (g1 m1) d1
                  (let ((offset (zpb-ttf:kerning-offset g0 g1 font)))
                    (unless (= offset 0)
                      (setf (gethash (cons (glyph-character m0) (glyph-character m1)) table)
                            (* offset scale)))))))
     finally (return table)))

(defun make-metrics (glyph-data scale ttf)
  (make-font-metrics :glyphs (mapcar (lambda (g) (getf g :metrics)) glyph-data)
                     :ascender (* scale (zpb-ttf:ascender ttf))
                     :descender (* scale (zpb-ttf:descender ttf))
                     :line-gap (* scale (zpb-ttf:line-gap ttf))
                     :kerning-table (make-kerning-table glyph-data scale ttf)))


(defun obtain-glyph-data (string font-scale scale spread ttf)
  (flet ((fscale (v)
           (ceiling (* v font-scale))))
    (loop for c across string
       ;; possibly check zpb-ttf:glyph-exists-p
       ;; instead of storing box or whatever
       ;; missing chars get replaced with?
       for g = (zpb-ttf:find-glyph c ttf)
       collect (multiple-value-bind (sdf padding) (sdf ttf g font-scale scale spread)
                 (list
                  :glyph g
                  :metrics (make-glyph-metrics
                            :character c
                            :origin (list (+ (ceiling (- (* font-scale (xmin g)))) padding)
                                          (+ (ceiling (- (* font-scale (ymin g)))) padding))
                            :advance-width (fscale (zpb-ttf:advance-width g))
                            :left-side-bearing (fscale (zpb-ttf:left-side-bearing g))
                            :right-side-bearing (fscale (zpb-ttf:right-side-bearing g)))
                  :sdf sdf)))))


(defun make-atlas (font-name pixel-size
                   &key (scale 8) (spread 0.1)
                     (string *default-characters*)
                     width height)
  (zpb-ttf:with-font-loader (ttf font-name)
    (let* ((font-height (- (zpb-ttf:ascender ttf)
                           (zpb-ttf:descender ttf)))
           (font-scale (/ pixel-size font-height))
           (glyph-data (obtain-glyph-data string font-scale scale spread ttf))
           (pack (pack (loop for g in glyph-data
                          for sdf = (getf g :sdf)
                          collect (list g (array-dimension sdf 1) (array-dimension sdf 0)))
                       :width width
                       :height height))
           (dims (loop for (nil x y w h) in pack
                    maximize (+ x w) into width
                    maximize (+ y h) into height
                    finally (return (list width height)))))
        (time
         (let* ((out (aa-misc:make-image (first dims) (second dims) #(0 0 0)))
                (write (aa-misc:image-put-pixel out #(255 255 255))))
           (loop for (g x y w h) in pack
              do (with-glyph-data (glyph metrics sdf padding) g
                   (setf (glyph-bounding-box metrics) (list x y (+ x w) (+ y h)))
                     (loop for ox from x
                        for ix below w
                        do (loop for oy from y
                              for iy below h
                              do (funcall write ox oy
                                          (aref sdf (- h iy 1) ix 0))))))
           (%make-atlas out (make-metrics glyph-data font-scale ttf)))))))

(defun save-atlas (atlas png-filename metrics-filename)
  (declare (ignore metrics-filename))
  (opticl:write-image-file png-filename (atlas-image atlas)))
