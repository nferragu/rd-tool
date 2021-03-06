require 'set'
require 'uri'
require 'socket'
require 'rest-client'
require 'json'
require 'yaml'

class Rundeck

  attr_reader :token, :instance, :url, :port

  def initialize(endpoint = nil, token = nil)

    #TODO: Factory for REST Client
    #TODO: Read token from file
    @config = YAML.load_file(File.join(File.dirname(File.dirname(__FILE__)), 'config.yaml'))

    @token = token
    @endpoint = endpoint
   
    @token ||= @config['rundeck_token']
    @endpoint ||= @config['rundeck_api_endpoint']
    @instance = URI(@endpoint).host

    raise "Rundeck #{instance} is not active or its API is not available!" unless rundeck_active?

  end

  def get(path, params={:content_type => :json, :accept => :json},qp=nil)
    RestClient.get build_uri(path,qp), params
  end

  def rundeck_active?
    result = system_info['system']['executions']['active'].class
  end

  def system_info
    JSON.parse(get("/api/14/system/info"))
  end

  def build_uri(path, query_parameters=nil)

    token_parameter = { :authtoken => token }

    if query_parameters.nil?
      query_parameters = token_parameter
    else
      query_parameters = query_parameters.merge(token_parameter)
    end

    qps = []
    query_parameters.each { |param, value| qps << param.to_s + '=' + value.to_s }
    qps = qps.join('&')

    "#{@endpoint}#{path}?#{qps}"
  end

  def job_run_by_name(project, name)
    ids = job_ids(project, {:jobExactFilter => name})
    if ids.count != 1
      puts "#{ids.count} jobs found!"
      return false
    end
    job_run_by_id(ids.first)
  end

  def job_run_by_id(id, options={})
    params = {:content_type => :json, :accept => :json}
    uri = build_uri("/api/14/job/#{id}/run")
    response_json = JSON.parse(RestClient.post(uri, options.to_json, params))
    puts "#{response_json['status']} on #{response_json['href']}"
  end

  def job_delete_by_group(project, group)
    job_delete(job_ids(project, { :groupPathExact => group }))
  end

  def job_delete(ids)
    if ids.count < 1
      puts "There is no jobs matching the given pattern"
      return true
    end
    params = {:content_type => :json, :accept => :json}
    uri = build_uri("/api/14/jobs/delete")
    response_json = JSON.parse(RestClient.post(uri, { 'ids' => ids }.to_json, params))
    allsuccessful = response_json['allsuccessful']
    if allsuccessful
      puts "#{response_json['requestCount']} jobs were deleted successfully"
    else
      puts response_json
    end
    return allsuccessful
  end

  def job_ids(project, filters={})
    params = {:accept => :json}
    qp = filters
    uri = build_uri("/api/14/project/#{project}/jobs", qp)
    response_json = JSON.parse(RestClient.get(uri, params))
    ids = []
    response_json.each { |id| ids << id['id'] }
    return ids
  end

  def jobs(project)
    response_json = JSON.parse(get("/api/14/project/#{project}/jobs"))
    jobs = Array.new
    response_json.each { |job| jobs << job['name'] }
    return jobs
  end

  def jobs_to_file(project, definition_file)
    response_yaml = get("/api/14/project/#{project}/jobs/export",{},{ :format => 'yaml' })
    FileUtils::mkdir_p File.dirname(definition_file)
    File.open(definition_file, 'w') { |file| file.write(response_yaml)}
  end

  def jobs_import(project, jobs_file)
    response_json = JSON.parse(RestClient.post build_uri("/api/14/project/#{project}/jobs/import", 
                    {:dupeOption => 'update', :uuidOption => 'remove'}), File.read(jobs_file), 
                    { :accept => :json, :content_type => 'application/yaml', :format => 'yaml'})

    succeeded = response_json['succeeded'].count
    failed = response_json['failed'].count
    skipped = response_json['skipped'].count

    raise "jobs import failed: #{failed} skipped: #{skipped} with json: #{response_json}" if failed != 0 or skipped != 0
    jobs = []
    response_json['succeeded'].each { |j| jobs << j['name']}
    puts "Project: #{project} Imported #{succeeded} jobs successfully: #{jobs}"

  end

  def projects
    response_json = JSON.parse(get("/api/14/projects"))
    projects = Array.new
    response_json.each { |project| projects << project['name'] }
    return projects
  end

  def projects_to_zip(directory)

    projects.each do |project|

      destination_file = File.join(directory, project + '.zip')
      puts "Export project #{project} to #{destination_file}"
      project_to_file(project, destination_file)
    end
  end

  def project_name_from_file(file_path)
    File.basename(file_path,'.zip')
  end

  def projects_to_zip_from_dir(projects_directory, projects_destination=File.dirname(projects_directory))

    Dir[File.join(projects_directory, '/*')].each do |d|
      if File.directory?(d)
        d = File.expand_path(d) 
        MyZip.new.zip(d, File.join(projects_destination, File.basename(d) + '.zip'))
      end
    end
 
  end

  def projects_unzip_to_dir(projects_directory, projects_destination, exclude_pattern=nil)

    Dir[File.join(projects_directory, '/*.zip')].each do |project_file|
      project_destination = File.join(projects_destination, project_name_from_file(project_file))
      puts "Decompressing #{project_file} to #{project_destination}"

      if exclude_pattern.nil?
        MyZip.new.unzip(project_file, project_destination)
      else
        MyZip.new.unzip(project_file, project_destination, exclude_pattern)
        clean_raw_project(project_destination) if File.exists?File.join(projects_destination,'.git')
      end

    end

  end

  alias_method :projects_unzip_to_repo, :projects_unzip_to_dir

  def project_to_file(project, zip_file)
    compressed_project = get("/api/14/project/#{project}/export")
    FileUtils::mkdir_p File.dirname(zip_file)
    File.open(zip_file, 'w') { |file| file.write(compressed_project)}
  end

  def projects_import(directory)
    Dir[File.join(directory,'*.zip')].each do |project_file|
      puts "Importing #{project_file}"
      project_import(project_file)
    end
  end

  def projects_delete_all
    projects.each do |project|
      project_delete(project)
    end
  end
  
  def project_delete(project_name)
    puts "Deleting #{project_name}"
    RestClient.delete build_uri("/api/14/project/#{project_name}")
  end

  def project_create(project_name)
    puts "Creating #{project_name}"
    response = RestClient.post build_uri("/api/14/projects"), { 'name' => project_name }.to_json, :content_type => :json, :accept => :json
  end

  def project_import(project_file, delete_project=true, import_executions=true)

    query_parameters = {
    
      :jobUuidOption => 'preserve',
      :importExecutions => import_executions.to_s,
      :importConfig => 'true',
      :importACL => 'true'
    }

    project_name = project_name_from_file(project_file)

    if delete_project == true and projects.include?(project_name)
        project_delete(project_name)
    end

    project_create(project_name) if not projects.include?(project_name)

    uri = build_uri("/api/14/project/#{project_name}/import", query_parameters)

    response_json = JSON.parse(RestClient.put uri, File.read(project_file) , {:content_type => :zip, :accept => :json})
    if response_json['import_status'] == 'successful'
      puts "Project #{project_name} imported successfully"
    else
      raise "Import failed for project #{project_name} because import_status = #{response_json['import_status']}" 
    end

  end

  def project_config(project, config=nil)
    if config == nil
        response_json = JSON.parse(get("/api/14/project/#{project}/config"))
    else
        raise "Config should be a Hash" if not config.is_a?(Hash)

        uri = build_uri("/api/14/project/#{project}/config")
        response_json = JSON.parse(RestClient.put uri, JSON.dump(config), {:content_type => :json, :accept => :json})  
    end
  end

  def clean_raw_project(directory)

    project_name = File.basename(directory)

    what_to_clean = ponse = [
      {:file => 'META-INF/MANIFEST.MF', :pattern_to_clean => '^Rundeck-Archive-Export-Date'},
      {:file => "rundeck-#{project_name}/files/etc/project.properties", :pattern_to_clean => '^#'}
    ]

    what_to_clean.each do |i|
      file = File.join(directory, i[:file])
      pattern = i[:pattern_to_clean]

      old_file = File.readlines(file)
      File.open(file, 'w') do |new_file|
        old_file.each do |line|
          new_file.write(line) if not line =~ /#{pattern}/
        end
      end   
    end

  end

  def iso_8601(date)
    Date.strptime(date.to_s, '%Y-%m-%d').to_s + "T00:00:00Z"
  end

  def purge_executions(days_to_keep)

    _end = Date.strptime((Date.today - days_to_keep).to_s, '%Y-%m-%d').to_s + "T00:00:00Z"
    ids = []

    projects.each do |project|

        offset = 0
        max = 25
        count = -1

        until count == 0 do
            qp = { :offset => offset, :max => max, :end => _end}
            executions = executions(project, qp)
            ids << get_executions_ids(executions)
            count = executions['paging']['count'].to_i
            offset += max
        end
    end

    ids = ids.flatten.to_set.to_a
    r, f, s = bulk_delete_executions(ids)
    puts "Total executions: #{r} Success: #{s} Failed: #{f}"

  end

  def bulk_delete_executions(ids)
    
    max = 25
    failed_count = 0
    success_count = 0
    request_count = 0

    ids.each_slice(max) do |chunk|
        reponse_json = JSON.parse(RestClient.post build_uri("/api/14/executions/delete"), { 'ids' => chunk }.to_json, :content_type => :json, :accept => :json)
        failed_count += reponse_json['failedCount'].to_i
        success_count += reponse_json['successCount'].to_i
        request_count += reponse_json['requestCount'].to_i
    end

    return request_count, failed_count, success_count
  end

  def get_executions_ids(executions)
    ids = []
    executions['executions'].find_all do |e|
      ids << e['id'] if e.has_key?('id')
    end
    ids
  end

  def executions(project, query_parameters=nil)
    JSON.parse(RestClient.get build_uri("/api/14/project/#{project}/executions", query_parameters), {:content_type => :json, :accept => :json})
  end

end

