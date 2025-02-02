begin
  require 'rubygems'
rescue LoadError
  puts "You must install rubygems to run this example"
  raise
end

begin
  require 'bundler/setup'
rescue LoadError
  puts "to set up this example, run these commands:"
  puts "  gem install bundler"
  puts "  bundle install"
  raise
end

require 'sinatra'
require 'oauth'
require 'oauth/request_proxy/rack_request'

# hard-coded oauth information for testing convenience
$oauth_key = "test"
$oauth_secret = "secret"

# sinatra wants to set x-frame-options by default, disable it
disable :protection
# enable sessions so we can remember the launch info between http requests, as
# the user takes the assessment
enable :sessions

# this is the entry action that Canvas (the LTI Tool Consumer) sends the
# browser to when launching the tool.
post "/assessment/start" do
  # first we have to verify the oauth signature, to make sure this isn't an
  # attempt to hack the planet
  begin
    signature = OAuth::Signature.build(request, :consumer_secret => $oauth_secret)
    signature.verify() or raise OAuth::Unauthorized
  rescue OAuth::Signature::UnknownSignatureMethod,
         OAuth::Unauthorized
    return %{unauthorized attempt. make sure you used the consumer secret "#{$oauth_secret}"}
  end

  # make sure this is an assignment tool launch, not another type of launch.
  # only assignment tools support the outcome service, since only they appear
  # in the Canvas gradebook.
  unless params['lis_outcome_service_url'] && params['lis_result_sourcedid']
    return %{It looks like this LTI tool wasn't launched as an assignment, or you are trying to take it as a teacher rather than as a a student. Make sure to set up an external tool assignment as outlined <a target="_blank" href="https://github.com/instructure/lti_example">in the README</a> for this example.}
  end

  # store the relevant parameters from the launch into the user's session, for
  # access during subsequent http requests.
  # note that the name and email might be blank, if the tool wasn't configured
  # in Canvas to provide that private information.
  %w(lis_outcome_service_url lis_result_sourcedid lis_person_name_full lis_person_contact_email_primary).each { |v| session[v] = params[v] }

  # that's it, setup is done. now send them to the assessment!
  redirect to("/assessment")
end

def username
  session['lis_person_name_full'] || 'Student'
end

get "/assessment" do
  # first make sure they got here through a tool launch
  unless session['lis_result_sourcedid']
    return %{You need to take this assessment through Canvas. (Since this uses a session, this may also indicate issues with setting cookies)}
  end

  # now render a simple form the user will submit to "take the quiz"
  <<-HTML
  <html>
    <head><title>Demo LTI Assessment Tool</title></head>
    <body>
      <h1>Demo LTI Assessment Tool</h1>
      <form action="/assessment" method="post">
        <p>Hi, #{username}. On a scale of <code>0.0</code> to <code>1.0</code>, how well would you say you did on this assessment?</p>
        <input name='score' type='text' width='5' id='score' />
        <input type='submit' value='Submit' />
        <p>If you want to enter an invalid score here, you can see how Canvas will reject it.</p>
      </form>
    </body>
  </html>
  HTML
end

# This is the action that the form submits to with the score that the student entered.
# In lieu of a real assessment, that score is then just submitted back to Canvas.
post "/assessment" do
  # obviously in a real tool, we're not going to let the user input their own score
  score = params['score']
  if !score || score.empty?
    redirect to("/assessment")
  end

  # now post the score to canvas. Make sure to sign the POST correctly with
  # OAuth 1.0, including the digest of the XML body. Also make sure to set the
  # content-type to application/xml.
  xml = %{
<?xml version = "1.0" encoding = "UTF-8"?>
<imsx_POXEnvelopeRequest xmlns = "http://www.imsglobal.org/lis/oms1p0/pox">
  <imsx_POXHeader>
    <imsx_POXRequestHeaderInfo>
      <imsx_version>V1.0</imsx_version>
      <imsx_messageIdentifier>12341234</imsx_messageIdentifier>
    </imsx_POXRequestHeaderInfo>
  </imsx_POXHeader>
  <imsx_POXBody>
    <replaceResultRequest>
      <resultRecord>
        <sourcedGUID>
          <sourcedId>#{session['lis_result_sourcedid']}</sourcedId>
        </sourcedGUID>
        <result>
          <resultScore>
            <language>en</language>
            <textString>#{score}</textString>
          </resultScore>
        </result>
      </resultRecord>
    </replaceResultRequest>
  </imsx_POXBody>
</imsx_POXEnvelopeRequest>
  }
  consumer = OAuth::Consumer.new($oauth_key, $oauth_secret)
  token = OAuth::AccessToken.new(consumer)
  response = token.post(session['lis_outcome_service_url'], xml, 'Content-Type' => 'application/xml')

  headers 'Content-Type' => 'text'
  %{
Your score has #{response.body.match(/\bsuccess\b/) ? "been posted" : "failed in posting"} to Canvas. The response was:

#{response.body}
  }
end
