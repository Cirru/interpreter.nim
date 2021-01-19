
{} (:package |test-string)
  :configs $ {} (:init-fn |test-string.main/main!) (:reload-fn |test-string.main/reload!)
  :files $ {}
    |test-string.main $ {}
      :ns $ quote
        ns test-string.main $ :require
      :defs $ {}

        |test-str $ quote
          defn test-str ()
            assert= (&str-concat |a |b) |ab
            assert= (&str-concat 1 2) |12
            assert= (str |a |b |c) |abc
            assert= (str 1 2 3) |123
            assert= (type-of (&str 1)) :string
            assert=
              replace "|this is a" |is |IS
              , "|thIS IS a"
            assert=
              split "|a,b,c" "|,"
              [] |a |b |c
            assert=
              split-lines "|a\nb\nc"
              [] |a |b |c
            assert=
              split |a中b文c |
              [] |a |中 |b |文 |c
            assert= 4
              count |good
            assert= |56789 $ substr |0123456789 5
            assert= |567 $ substr |0123456789 5 8
            assert= | $ substr |0123456789 10
            assert= | $ substr |0123456789 9 1
            assert= -1 $ compare-string |a |b
            assert= 1 $ compare-string |b |a
            assert= 0 $ compare-string |a |a

        |test-contains $ quote
          fn ()
            assert= true $ contains? |abc |abc
            assert= false $ contains? |abd |abc

            assert= 3 $ str-find |0123456 |3
            assert= 3 $ str-find |0123456 |34
            assert= 0 $ str-find |0123456 |01
            assert= 4 $ str-find |0123456 |456
            assert= -1 $ str-find |0123456 |98

            assert= true $ starts-with? |01234 |0
            assert= true $ starts-with? |01234 |01
            assert= false $ starts-with? |01234 |12

            assert= true $ ends-with? |01234 |34
            assert= true $ ends-with? |01234 |4
            assert= false $ ends-with? |01234 |23

        |test-parse $ quote
          fn ()
            assert= 0 $ parse-float |0

        |test-trim $ quote
          fn ()
            assert= | $ trim "|    "
            assert= |1 $ trim "|  1  "

            assert= | $ trim "|______" |_
            assert= |1 $ trim "|__1__" |_

        |log-title $ quote
          defn log-title (title)
            echo
            echo title
            echo

        |test-format $ quote
          fn ()
            log-title "|Testing format"

            assert= |1.2346 $ format-number 1.23456789 4
            assert= |1.235 $ format-number 1.23456789 3
            assert= |1.23 $ format-number 1.23456789 2
            assert= |1.2 $ format-number 1.23456789 1

        |test-char $ quote
          fn ()
            log-title "|Test char"

            assert= 97 $ get-char-code |a
            assert= 27721 $ get-char-code |汉

            assert= |a $ first |abc
            assert= |c $ last |abc
            assert= nil $ first |
            assert= nil $ last |

        |test-re $ quote
          fn ()
            log-title "|Test regular expression"

            assert= true $ re-matches |\d |2
            assert= true $ re-matches |\d+ |23
            assert= false $ re-matches |\d |a

            assert= 1 $ re-find-index |\d |a1
            assert= -1 $ re-find-index |\d |aa

            assert= ([] |1 |2 |3) $ re-find-all |\d |123
            assert= ([] |123) $ re-find-all |\d+ |123
            assert= ([] |1 |2 |3) $ re-find-all |\d+ |1a2a3
            assert= ([] |1 |2 |34) $ re-find-all |\d+ |1a2a34

        |test-whitespace $ quote
          fn ()
            log-title "|Test blank?"

            assert-detect identity $ blank? |
            assert-detect identity $ blank? "\""
            assert-detect identity $ blank? "| "
            assert-detect identity $ blank? "|  "
            assert-detect identity $ blank? "|\n"
            assert-detect identity $ blank? "|\n "
            assert-detect not $ blank? |1
            assert-detect not $ blank? "| 1"
            assert-detect not $ blank? "|1 "

        |main! $ quote
          defn main! ()
            log-title "|Testing str"
            test-str

            log-title "|Testing contains"
            test-contains

            log-title "|Testing parse"
            test-parse

            log-title "|Testing trim"
            test-trim

            test-format

            test-char

            test-re

            test-whitespace

            do true

      :proc $ quote ()
      :configs $ {} (:extension nil)
