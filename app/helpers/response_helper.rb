class ResponseHelper
  include Scoring

  # sorts the questions passed by sequence number in ascending order
  def sort_questions(questions)
    questions.sort_by(&:seq)
  end
  # checks if the questionnaire is nil and opens drop down or rating accordingly
  def set_dropdown_or_scale(response_dto)
    # todo: create a dropdown column to AssignmentQuestionnaire
    # use_dropdown = AssignmentQuestionnaire.where(assignment_id: response_dto.assignment.try(:id),
    #                                              questionnaire_id: response_dto.questionnaire.try(:id))
    #                                       .first.try(:dropdown)
    use_dropdown= true
    dropdown_or_scale = (use_dropdown ? 'dropdown' : 'scale')
    return dropdown_or_scale
  end

  # This method is called within set_content and when the new_response flag is set to true
  # Depending on what type of response map corresponds to this response, the method gets the reference to the proper questionnaire
  # This is called after assign_instance_vars in the new method
  def questionnaire_from_response_map(response_dto)
    case response_dto.map.type
    when 'ReviewResponseMap', 'SelfReviewResponseMap'
      reviewees_topic = SignedUpTeam.topic_id_by_team_id(@contributor.id)
      @current_round = @assignment.number_of_current_round(reviewees_topic)
      @questionnaire = @map.questionnaire(@current_round, reviewees_topic)
    when
    'MetareviewResponseMap',
      'TeammateReviewResponseMap',
      'FeedbackResponseMap',
      'CourseSurveyResponseMap',
      'AssignmentSurveyResponseMap',
      'GlobalSurveyResponseMap',
      'BookmarkRatingResponseMap'
      if response_dto.assignment.duty_based_assignment?
        # E2147 : gets questionnaire of a particular duty in that assignment rather than generic questionnaire
        response_dto.questionnaire = response_dto.map.questionnaire_by_duty(response_dto.map.reviewee.duty_id)
      else
        response_dto.questionnaire = response_dto.map.questionnaire
      end
    end
  end


  # This method is called within set_content when the new_response flag is set to False
  # This method gets the questionnaire directly from the response object since it is available.
  def questionnaire_from_response(response_dto)
    # if user is not filling a new rubric, the response_dtoresponse object should be available.
    # we can find the questionnaire from the question_id in answers
    answer = response_dto.response.scores.first
    response_dto.questionnaire = response_dto.response.questionnaire_by_answer(answer)
  end
  def score(params)
    Class.new.extend(Scoring).assessment_score(params)
  end
  def questionnaire_by_answer(answer)
    if answer.nil?
      # there is small possibility that the answers is empty: when the questionnaire only have 1 question and it is a upload file question
      # the reason is that for this question type, there is no answer record, and this question is handled by a different form
      map = ResponseMap.find(map_id)
      # E-1973 either get the assignment from the participant or the map itself
      assignment = if map.is_a? ReviewResponseMap
                     map.assignment
                   else
                     Participant.find(map.reviewer_id).assignment
                   end
      questionnaire = Questionnaire.find(assignment.review_questionnaire_id)
    else # for all the cases except the case that  file submission is the only question in the rubric.
      questionnaire = Question.find(answer.question_id).questionnaire
    end
    questionnaire
  end
  # For each question in the list, starting with the first one, you update the comment and score
  def create_answers(response, params, questions)
    params[:responses].each_pair do |k, v|
      score = Answer.where(response_id: response.id, question_id: questions[k.to_i].id).first
      score ||= Answer.create(response_id: response.id, question_id: questions[k.to_i].id, answer: v[:score], comments: v[:comment])
      score.update_attribute('answer', v[:score])
      score.update_attribute('comments', v[:comment])
    end
  end
  def notify_instructor_on_difference(response)
    response_map = response.map
    reviewer_participant_id = response_map.reviewer_id
    reviewer_participant = AssignmentParticipant.find(reviewer_participant_id)
    reviewer_name = User.find(reviewer_participant.user_id).fullname
    reviewee_team = AssignmentTeam.find(response_map.reviewee_id)
    reviewee_participant = reviewee_team.participants.first # for team assignment, use the first member's name.
    reviewee_name = User.find(reviewee_participant.user_id).fullname
    assignment = Assignment.find(reviewer_participant.parent_id)
    Mailer.notify_grade_conflict_message(
      to: assignment.instructor.email,
      subject: 'Expertiza Notification: A review score is outside the acceptable range',
      body: {
        reviewer_name: reviewer_name,
        type: 'review',
        reviewee_name: reviewee_name,
        new_score: aggregate_questionnaire_score.to_f / maximum_score,
        assignment: assignment,
        conflicting_response_url: 'https://expertiza.ncsu.edu/response/view?id=' + response_id.to_s,
        summary_url: 'https://expertiza.ncsu.edu/grades/view_team?id=' + reviewee_participant.id.to_s,
        assignment_edit_url: 'https://expertiza.ncsu.edu/assignments/' + assignment.id.to_s + '/edit'
      }
    ).deliver_now
  end
  # compare the current response score with other scores on the same artifact, and test if the difference
  # is significant enough to notify instructor.
  # Precondition: the response object is associated with a ReviewResponseMap
  ### "map_class.assessments_for" method need to be refactored
  def significant_difference?(response)
    map = response.map
    map_class = map.class
    existing_responses = map_class.assessments_for(map.reviewee)
    average_score_on_same_artifact_from_others, count = Response.avg_scores_and_count_for_prev_reviews(existing_responses, self)
    # if this response is the first on this artifact, there's no grade conflict
    return false if count.zero?

    # This score has already skipped the unfilled scorable question(s)
    score = response.aggregate_questionnaire_score.to_f / maximum_score
    questionnaire = response.questionnaire_by_answer(scores.first)
    assignment = map.assignment
    assignment_questionnaire = AssignmentQuestionnaire.find_by(assignment_id: assignment.id, questionnaire_id: questionnaire.id)
    # notification_limit can be specified on 'Rubrics' tab on assignment edit page.
    allowed_difference_percentage = assignment_questionnaire.notification_limit.to_f
    # the range of average_score_on_same_artifact_from_others and score is [0,1]
    # the range of allowed_difference_percentage is [0, 100]
    (average_score_on_same_artifact_from_others - score).abs * 100 > allowed_difference_percentage
  end
  # only two types of responses more should be added
  def email(partial = 'new_submission', map_id)

    defn = {}
    defn[:body] = {}
    defn[:body][:partial_name] = partial
    response_map = ResponseMap.find map_id
    participant = Participant.find(response_map.reviewer_id)
    # parent is used as a common variable name for either an assignment or course depending on what the questionnaire is associated with
    parent = if response_map.survey?
               response_map.survey_parent
             else
               Assignment.find(participant.parent_id)
             end
    defn[:subject] = 'A new submission is available for ' + parent.name
    response_map.email(defn, participant, parent)
  end

end