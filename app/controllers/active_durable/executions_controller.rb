# frozen_string_literal: true

module ActiveDurable
  # Lists executions, shows their notebook and runs the operator actions.
  class ExecutionsController < ApplicationController
    PER_PAGE = 50

    rescue_from ActiveDurable::Error do |error|
      redirect_to execution_path(params[:id]), alert: error.message
    end

    def index
      @page = [params[:page].to_i, 1].max
      rows = filtered_executions.offset((@page - 1) * PER_PAGE).limit(PER_PAGE + 1).to_a
      @next_page = rows.size > PER_PAGE
      @executions = rows.first(PER_PAGE)
      @steps_by_execution = Step.where(execution_id: @executions.map(&:id)).order(:id).group_by(&:execution_id)
      @counts = Execution.group(:status).count
      @recipes = Execution.distinct.order(:recipe).pluck(:recipe)
    end

    def show
      @execution = Execution.find(params[:id])
      steps = @execution.steps.to_a
      @steps = steps
      @forward_steps = steps.select(&:forward?).sort_by { |step| step.position.to_i }
      @undo_steps = steps.select(&:undo?)
      @hook_steps = steps.select(&:hook?)
      @signals = @execution.signals.to_a
      @reruns = Execution.where(forked_from: @execution.id).order(:created_at).to_a
    end

    def retry_now
      ActiveDurable.retry(params[:id])
      redirect_to execution_path(params[:id]), notice: "Retrying. Failed steps got a fresh set of attempts."
    end

    def compensate
      ActiveDurable.compensate(params[:id], reason: "Compensated from the dashboard")
      redirect_to execution_path(params[:id]), notice: "Compensation started."
    end

    def rerun
      execution = ActiveDurable.rerun(params[:id], from: params.require(:from))
      redirect_to execution_path(execution), notice: "New execution started from :#{params[:from]}."
    end

    private

    def filtered_executions
      scope = Execution.order(updated_at: :desc)
      @status = params[:status].presence_in(Execution::STATUSES)
      scope = scope.where(status: @status) if @status
      @recipe = params[:recipe].presence
      scope = scope.where(recipe: @recipe) if @recipe
      @query = params[:q].to_s.strip
      @query.present? ? scope.where("id LIKE ?", "%#{Execution.sanitize_sql_like(@query)}%") : scope
    end
  end
end
