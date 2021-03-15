require 'octokit'
require 'rubygems'
require 'dogapi'
require 'date'
require 'json'

def collect_metrics(jobs, tags)
  jobs.map{|job| collect_job_metrics(job, tags)}.compact + \
  collect_workflow_metrics(jobs, tags)
end

def collect_job_metrics(job, tags)
  return nil unless job["status"] == "completed"
  [
    "job_duration",
    job["completed_at"] - job["started_at"],
    tags + ["status:#{job["conclusion"]}", "name:#{job["name"]}"]
  ]
end

def collect_workflow_metrics(jobs, tags)
  start = jobs.min_by{|job| job["started_at"]}["started_at"]
  finish = jobs.max_by{|job| job["completed_at"]}["completed_at"]
  status = jobs.all?{|job| ["success", "skipped"].include? job["conclusion"]} ? "success" : "failure"
  [[
    "workflow_duration",
    finish - start,
    tags + ["status:#{status}"]
  ]]
end

def submit_metrics(metrics, datadog_client, metric_prefix)
  datadog_client.batch_metrics do
    metrics.each do |metric, value, tags|
      metric = metric_prefix + metric
      puts "#{metric}, #{value}, #{tags}"
      datadog_client.emit_point(metric, value, :tags => tags, :type => 'gauge')
      datadog_client.emit_point(metric + ".count", 1, :tags => tags, :type => 'counter')
    end
  end
end

def prior_jobs(jobs)
  jobs.select{|job| !job["conclusion"].nil? }
end

def collect_merged_data(github_client, repo, teams)
  pr_info = github_client.pull_request(repo, ENV['PR_NUMBER'])
  time_to_merge = pr_info["merged_at"] - pr_info["created_at"]
  diff_size = pr_info["additions"] + pr_info["deletions"]
  tags = ["project:#{repo}"]
  tags += teams.map{|team| "team:#{team}"} if teams && teams.count.positive?
  [
    ["time_to_merge", time_to_merge, tags],
    ["lines_changed", diff_size, tags]
  ]
end

def collect_opened_data(github_client, repo)
  pr_info = github_client.pull_request(repo, ENV['PR_NUMBER'])
  commits = github_client.get(pr_info["commits_url"])
  time_to_open = pr_info["created_at"] - commits.first["commit"]["committer"]["date"]
  [["time_to_open", time_to_open, ["project:#{repo}"]]]
end

def collect_duration_data(github_client, repo, run)
  workflow = github_client.get("repos/#{repo}/actions/runs/#{run}")
  tags = ["workflow:#{workflow["name"]}", "project:#{repo}"]
  jobs = prior_jobs(github_client.get(workflow["jobs_url"])["jobs"])
  collect_metrics(jobs, tags)
end

repo = ARGV[0].strip
run = ARGV[1].strip
metric_prefix = ARGV[2].strip
teams = ARGV[3].nil? || ARGV[3] == '' ? [] : JSON.parse(ARGV[3].strip)
metric_prefix += "." unless metric_prefix.end_with?(".")
datadog_client = Dogapi::Client.new(ENV['DATADOG_API_KEY'])
github_client = Octokit::Client.new(:access_token => ENV['OCTOKIT_TOKEN'])

metrics = nil

case ENV['ACTION'].strip
when "closed"
  metrics = collect_merged_data(github_client, repo, teams)
when "opened"
  metrics = collect_opened_data(github_client, repo)
when "job_metrics"
  metrics = collect_duration_data(github_client, repo, run)
end

submit_metrics(metrics, datadog_client, metric_prefix) if metrics
