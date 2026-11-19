#!/usr/bin/env bb
;; opengrep-diff.bb <rawpaco> <opengrep> <ケースのディレクトリ>...
;; 論理結合の差分テスト（設計書 OPENGREP_RULE_ENGINE_DESIGN 7.3）。各ケースのディレクトリには
;; rules.yml（opengrep の形式、languages: [regex]）と target.pas を置く。同じルールを
;; opengrep にはそのまま、rawpaco には languages を [pascal] に替えた JSON で渡し、
;; ルールごとの一致のバイト範囲の集合を比べる。
;; ケースに expected-diff.txt があれば、食い違いがその内容と一致する限り成功とする
;; （opengrep と意図して違えた点を、理由とともにそこへ残す）。
(require '[babashka.process :refer [shell]]
         '[babashka.fs :as fs]
         '[cheshire.core :as json]
         '[clj-yaml.core :as yaml]
         '[clojure.set :as set]
         '[clojure.string :as str])

;; opengrep はルール ID の前に設定ファイルの場所を「.」区切りで付けることがあるので、
;; 最後の要素だけを使う。ケースのルール ID には「.」を使わない。
(defn short-id [id] (last (str/split id #"\.")))

(defn opengrep-ranges [og dir]
  (let [{:keys [out exit]} (shell {:dir (str dir) :out :string :err :string :continue true}
                                  og "scan" "--config" "rules.yml" "--json"
                                  "--disable-version-check" "target.pas")
        body (json/parse-string out true)]
    ;; 1 は「一致あり」。それ以外の非 0 はルールが受け付けられなかったことを示す
    (when-not (#{0 1} exit)
      (throw (ex-info (str "opengrep failed in " dir ": " out) {})))
    (when (seq (:errors body))
      (throw (ex-info (str "opengrep reported errors in " dir ": "
                           (json/generate-string (:errors body))) {})))
    (set (for [r (:results body)]
           [(short-id (:check_id r)) (-> r :start :offset) (-> r :end :offset)]))))

(defn rawpaco-ranges [rp dir tmp]
  (let [rules (yaml/parse-string (slurp (str (fs/path dir "rules.yml"))))
        rules (update rules :rules
                      (fn [rs] (mapv #(assoc % :languages ["pascal"]) rs)))
        jf (str (fs/path tmp "rules.json"))
        _ (spit jf (json/generate-string rules))
        target (str (fs/path dir "target.pas"))
        {:keys [out exit err]} (shell {:out :string :err :string :continue true}
                                      rp (str "--match-rules=" jf) target)]
    (when-not (zero? exit)
      (throw (ex-info (str "rawpaco failed in " dir ": " err out) {})))
    ;; 標準出力の先頭にはバージョン表示が出るので、形の合う行だけを拾う
    (set (for [line (str/split-lines out)
               :let [[_ id s e] (re-matches #".*:([^:]+):(\d+)-(\d+)" line)]
               :when id]
           [id (parse-long s) (parse-long e)]))))

(defn diff-lines [og rp]
  (sort (concat (for [[id s e] (set/difference og rp)] (format "only-opengrep %s %d-%d" id s e))
                (for [[id s e] (set/difference rp og)] (format "only-rawpaco %s %d-%d" id s e)))))

(let [[rp og & dirs] *command-line-args*
      tmp (fs/create-temp-dir)
      failed (atom 0)]
  (when (or (nil? og) (empty? dirs))
    (binding [*out* *err*] (println "usage: opengrep-diff.bb <rawpaco> <opengrep> <case-dir>..."))
    (System/exit 2))
  (try
    (doseq [dir dirs]
      (let [d (diff-lines (opengrep-ranges og dir) (rawpaco-ranges rp dir tmp))
            ef (fs/path dir "expected-diff.txt")
            expected (if (fs/exists? ef)
                       (vec (remove #(or (str/blank? %) (str/starts-with? % "#"))
                                    (str/split-lines (slurp (str ef)))))
                       [])]
        (if (= (vec d) (vec (sort expected)))
          (println "ok  " (fs/file-name dir) (if (seq d) (str "(" (count d) " expected diff(s))") ""))
          (do (swap! failed inc)
              (println "FAIL" (fs/file-name dir))
              (doseq [l d] (println "  got:     " l))
              (doseq [l expected] (println "  expected:" l))))))
    (finally (fs/delete-tree tmp)))
  (println (format "opengrep-diff: %d case(s), %d failed" (count dirs) @failed))
  (System/exit (if (pos? @failed) 1 0)))
