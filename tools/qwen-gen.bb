#!/usr/bin/env bb
;; qwen.bb プロンプトファイル 出力ファイル
;; ollama の HTTP API で qwen3.8-27b-64k を呼ぶ。思考トークンでコンテキストを使い切ると
;; 出力が黙って途中で切れるので、done_reason が stop 以外なら失敗にする。
(require '[babashka.http-client :as http]
         '[cheshire.core :as json]
         '[clojure.string :as str])

(let [[pf of] *command-line-args*
      model (or (System/getenv "QWEN_MODEL") "qwen3.8-27b-64k")
      resp (http/post "http://127.0.0.1:11434/api/generate"
                      {:headers {"Content-Type" "application/json"}
                       :body (json/generate-string
                              {:model model :prompt (slurp pf) :stream false
                               :options {:temperature 0.1 :num_ctx 65536}})
                       :timeout 3600000 :throw false})
      body (json/parse-string (:body resp) true)]
  (when-not (= 200 (:status resp))
    (binding [*out* *err*] (println "ollama error" (:status resp) (:body resp)))
    (System/exit 1))
  (let [text (-> (:response body)
                 (str/replace #"(?m)^```[a-zA-Z]*\s*$" "")
                 str/trim)]
    (spit of (str text "\n"))
    (println "done_reason:" (:done_reason body) "eval_count:" (:eval_count body)
             "lines:" (count (str/split-lines text)))
    (when-not (= "stop" (:done_reason body))
      (binding [*out* *err*] (println "出力が途中で切れた"))
      (System/exit 1))))
