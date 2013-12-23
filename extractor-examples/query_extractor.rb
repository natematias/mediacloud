require 'net/http'
require 'hpricot'
require 'json'

#ruby query_extractor.rb <url> <extractor_hostname> <extractor_port>

#download an article from the Telegraph

uri = ARGV[0] || "http://www.bbc.co.uk/newsbeat/20714096"
extractor_hostname = ARGV[1] || ""
port = ARGV[2] || "3000"

#parse the title

html = Net::HTTP.get(URI(uri))

http = Net::HTTP.new("ec2-23-22-34-227.compute-1.amazonaws.com", port)
request = Net::HTTP::Put.new("/api/extractor/v1/extractor/extract")
request.set_form_data({"title"=>"Call Me Maybe named as the most watched video of 2012", "doc"=>html})
response = http.request(request)

puts JSON.parse(response.body)
