(cl:in-package #:cl-multiaddr)

(defun code-to-varint (code)
  (declare (type integer code))
  (let* ((buffer (make-sequence '(vector (unsigned-byte 8)) (round (1+ (/ code 7)))))
	 (index (varint:encode-uint64 buffer 0 code)))
    (subseq buffer 0 index)))

(defun varint-to-code (buffer)
  (declare (type (vector (unsigned-byte 8)) buffer))
  (varint:parse-uint64 buffer 0))

(defun string-to-bytes (string)
  (declare (type string string))
  (let* ((string (ppcre:regex-replace "(/+$)" string ""))
	 (split (split-sequence:split-sequence #\/ string)))
    (unless (string= (car split) "")
      (error 'invalid-multiaddr))
    (loop
       with split1 = (cdr split)
       until (zerop (length split1))
       for protocol = (protocol-with-name (car split1))
       collect (code-to-varint (protocol-code protocol)) into bytes
       do (setf split1 (cdr split1))
       unless (zerop (protocol-size protocol))
       if (zerop (length split1))
       do (error "protocol requires address, none given: ~A" (protocol-name protocol))
       end and
       collect (address-string-to-bytes protocol (car split1)) into bytes
       and do (setf split1 (cdr split1))
       finally (return (apply #'concatenate '(vector (unsigned-byte 8)) bytes)))))

(defun bytes-to-string (bytes)
  (declare (type (vector (unsigned-byte 8)) bytes))
  (loop with bytes = (copy-seq bytes)
     with string = ""
     for (code index) = (multiple-value-list (varint-to-code bytes))
     until (zerop (length bytes))
     for protocol = (protocol-with-code code)
     do (setf bytes (subseq bytes index))
     do (setf string (concatenate 'string string "/" (protocol-name protocol)))
     unless (zerop (protocol-size protocol))
     do (let* ((size (size-for-addr protocol bytes))
	       (address-string (address-bytes-to-string protocol (subseq bytes 0 size))))
	  (unless (zerop (length address-string))
	    (setf string (concatenate 'string string "/" address-string)))
	  (setf bytes (subseq bytes size)))
     finally (return string)))

(defun size-for-addr (protocol bytes)
  (declare (type protocol protocol)
	   (type (vector (unsigned-byte 8)) bytes))
  (cond
    ((> (protocol-size protocol) 0)
     (round (/ (protocol-size protocol) 8)))
    ((zerop (protocol-size protocol)) 0)
    (t
     (let ((code-index (multiple-value-list (varint-to-code bytes))))
       (+ (first code-index) (second code-index)))))) ;?

(defun bytes-split (bytes)
  (declare (type (vector (unsigned-byte 8)) bytes))
  (loop
     for bytes1 = (copy-seq bytes) then (subseq bytes1 length)
     until (zerop (length bytes1))
     for (code index) = (multiple-value-list (varint-to-code bytes1))
     for protocol = (protocol-with-code code)
     for length = (+ index (size-for-addr protocol (subseq bytes1 index)))
     collect (subseq bytes1 0 length)))

(defun address-string-to-bytes (protocol string)
  (declare (type protocol protocol)
	   (type string string))
  (let ((code (protocol-code protocol)))
    (cond
      ((= code +p-ip4+)
       (let ((buffer (make-array 4 :element-type '(unsigned-byte 8))))
	 (usocket:ip-to-octet-buffer string buffer)
	 buffer))
      ((= code +p-ip6+)
       (usocket:ipv6-host-to-vector string))
      ((or
	(= code +p-tcp+)
	(= code +p-udp+)
	(= code +p-dccp+)
	(= code +p-sctp+))
       (let ((port (parse-integer string)))
	 (if (>= port 65536)
	     (error "~D is greater than 65536" port))
	 (octets-util:integer-to-octets port :n-bits 16)))
      ((= code +p-ipfs+)
       (let* ((multihash (multihash:from-base58 string))
	      (size (code-to-varint (length multihash))))
	 (concatenate '(vector (unsigned-byte 8)) size multihash)))
      (t (error 'invalid-protocol)))))
  
(defun address-bytes-to-string (protocol bytes)
  (declare (type protocol protocol)
	   (type (vector (unsigned-byte 8)) bytes))
  (let ((code (protocol-code protocol)))
    (cond
      ((= code +p-ip4+)
       (format nil "~{~A~^.~}" (coerce bytes 'list)))
      ((= code +p-ip6+)
       (usocket:vector-to-ipv6-host bytes))
      ((or
	(= code +p-tcp+)
	(= code +p-udp+)
	(= code +p-dccp+)
	(= code +p-sctp+))
       (format nil "~D" (octets-util:octets-to-integer bytes)))
      ((= code +p-ipfs+)
       (multiple-value-bind (size index)
	   (varint-to-code bytes)
	 (let ((bytes (subseq bytes index)))
	   (unless (= (length bytes) size)
	     (error "Inconsistent Lengths"))
	   (multihash:to-base58 bytes))))
      (t (error 'invalid-protocol)))))
